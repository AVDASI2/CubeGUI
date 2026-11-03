classdef Cube < handle
    %CUBE  Everything a panel can ask of the Cube (or the simulation).
    %
    %   Part of CubeGUI's engine. You don't need to change this: see the
    %   panels folder and docs/recipes.md.
    %
    %   Every panel is given one of these, called cube. It's the only way a
    %   panel talks to the Cube, and everything on it is safe to call from
    %   anywhere, as often as you like:
    %
    %     cube.moveServo("Elevator", 10)   move a servo, in its own units (% or deg)
    %     cube.moveServoPwm("Elevator", 1600)  move a servo to a PWM (us), e.g. for calibrating
    %     cube.zeroAll()                   every servo to its trim position
    %     cube.latest("pitch")             the newest value of a signal, or NaN
    %     [t, y] = cube.history("pitch")   the plot window's worth (t = 0 is now)
    %     cube.units("pitch")              e.g. "deg"
    %     s = cube.servo("Elevator")       a servo's details (see servo below)
    %     cube.servoTarget("Elevator")     the last position asked for, in its units
    %     cube.servoSent("Elevator")       the last position actually sent, in its units
    %     cube.servoNames()                every servo's name, from the settings
    %     cube.isConnected()
    %     cube.say("text")                 a message in the status line
    %     cube.mark("run 3 start")         a run marker, in both logs
    %
    %   From level 2, with lua/cubegui.lua on the Cube:
    %     m = cube.mode()                  who's in charge of the servos (see mode below)
    %     cube.requestMode("closed loop")  or "gui": ask the script for a mode
    %     cube.setPitchTarget(5)           the closed loop's pitch target, degrees
    %     cube.setSas(true)                stability augmentation on or off
    %
    %   A signal is anything with a value that changes over time: "pitch",
    %   "pitch rate", a servo's name (the position the Cube reports for it),
    %   "rc1" to "rc18" (the transmitter's channels, in us), or the name of
    %   a value sent by a Lua script (gcs:send_named_float).
    %
    %   The safety rules live here and in DataSource, where a panel can't
    %   undo them: every servo command is turned into PWM using the Cube's
    %   own limits, clamped to them, and sent at most 10 times a second per
    %   servo. Nothing here arms the Cube, writes parameters or changes the
    %   safety switch.

    properties (SetAccess = private)
        Level            % the capability level the window was opened at
        PlotSeconds      % how many seconds a plot shows
    end

    properties (Constant)
        SendInterval = 0.1   % at most 10 commands a second for each servo
    end

    properties (Access = private)
        Telemetry
        Source = []      % the connected DataSource, or [] when not connected
        Say              % function that puts a message in the status line
        Servos           % one struct per servo: settings, limits, mapping, state
        LimitsParamCount = -1   % Telemetry.ParamCount when the limits were last checked
        Requested = struct("mode", 0, "target", 0, "sas", false)   % what CubeGUI asks the script for
        RequestPending = false   % a change not yet sent (the rate limit held it back)
        LastRequestSend = uint64(0)
    end

    properties (Constant, Access = private)
        ScriptTimeout = 2   % seconds without CG_MODE before the script counts as absent
        ModeNames = ["CubeGUI", "Transmitter (RC)", "Closed loop"]   % CG_MODE 0, 1, 2
    end

    methods
        function obj = Cube(telemetry, servos, level, plotSeconds, say)
            % Made by the window. servos: config.servos from loadConfig.
            obj.Telemetry = telemetry;
            obj.Level = level;
            obj.PlotSeconds = plotSeconds;
            obj.Say = say;
            obj.Servos = struct("name", {}, "output", {}, "settings", {}, "mapping", {}, ...
                "limits", {}, "ready", {}, "why", {}, "target", {}, "pending", {}, "lastSend", {}, ...
                "scriptWhy", {});
            for s = reshape(servos, 1, [])
                obj.Servos(end+1) = struct("name", s.name, "output", s.output, "settings", s, ...
                    "mapping", s.mapping, "limits", NaN(1, 3), "ready", false, ...
                    "why", "Connect to use this servo.", "target", NaN, "pending", NaN, ...
                    "lastSend", uint64(0), "scriptWhy", "");
            end
        end

        % ---- Servos ----------------------------------------------------------

        function moveServo(obj, name, value)
            % Move a servo to value, in its own units (PWM in µs, or degrees
            % once calibrated). Values beyond the slider's range are held at
            % its ends. Commands come at most 10 times a second per servo;
            % one that comes too soon is sent on the next tick, so the last
            % position asked for is never lost.
            k = obj.find(name);
            s = obj.Servos(k);
            value = min(max(value, s.mapping.Range(1)), s.mapping.Range(2));
            obj.Servos(k).target = value;
            if ~obj.usable(k)
                obj.say(obj.whyNot(k), true);
                return
            end
            if s.lastSend == 0 || toc(s.lastSend) >= obj.SendInterval
                obj.send(k, s.mapping.toPwm(value));
            else
                obj.Servos(k).pending = value;
            end
        end

        function moveServoPwm(obj, name, pwm)
            % Move a servo to a PWM value in microseconds, rather than its
            % units: for calibrating, when the units aren't known yet. The
            % same rules apply: held within the Cube's SERVOn_MIN/MAX, and
            % at most 10 commands a second.
            k = obj.find(name);
            s = obj.Servos(k);
            if ~obj.usable(k)
                obj.say(obj.whyNot(k), true);
                return
            end
            pwm = min(max(pwm, s.limits(1)), s.limits(3));
            value = s.mapping.toValue(pwm);
            obj.Servos(k).target = value;
            if s.lastSend == 0 || toc(s.lastSend) >= obj.SendInterval
                obj.send(k, pwm);
            else
                obj.Servos(k).pending = value;
            end
        end

        function zeroAll(obj)
            % Send every servo exactly its trim PWM (the Cube's SERVOn_TRIM).
            sent = 0;
            for k = 1:numel(obj.Servos)
                s = obj.Servos(k);
                if obj.usable(k)
                    obj.Servos(k).target = s.mapping.toValue(s.limits(2));
                    obj.Servos(k).pending = NaN;
                    obj.send(k, s.limits(2));
                    sent = sent + 1;
                end
            end
            if isempty(obj.Source)
                obj.say("Not connected, so nothing was sent. Click Connect first.", true);
            elseif sent == numel(obj.Servos)
                obj.say("Sent every servo to its trim position.");
            else
                obj.say(sprintf(['Sent %d of %d servos to trim. CubeGUI can''t drive the ' ...
                    'others just now: see their panels.'], sent, numel(obj.Servos)), true);
            end
        end

        function info = servo(obj, name)
            % One servo's details, as a struct:
            %   name, output    from the settings, e.g. "Elevator", 5
            %   units, range    the slider's units and ends, e.g. "µs", [1100 1900]
            %   trim            SERVOn_TRIM in the slider's units (NaN until read)
            %   ready           true when CubeGUI can drive it (limits read, and
            %                   the Cube's script isn't driving it instead)
            %   why             if not ready, why not, in a few words
            %   minPwm, trimPwm, maxPwm   its limits on the Cube (NaN until read)
            k = obj.find(name);
            s = obj.Servos(k);
            [ready, why] = obj.usable(k);
            info = struct("name", s.name, "output", s.output, "units", s.mapping.Units, ...
                "range", s.mapping.Range, "trim", s.mapping.toValue(s.limits(2)), ...
                "ready", ready, "why", why, ...
                "minPwm", s.limits(1), "trimPwm", s.limits(2), "maxPwm", s.limits(3));
        end

        function names = servoNames(obj)
            names = [obj.Servos.name];
        end

        function value = servoTarget(obj, name)
            % The last position asked for (by any panel, or Zero all), in its units.
            value = obj.Servos(obj.find(name)).target;
        end

        function value = servoSent(obj, name)
            % The last position actually sent to the Cube, in its units, or NaN.
            s = obj.Servos(obj.find(name));
            value = NaN;
            if ~isempty(obj.Source)
                value = s.mapping.toValue(obj.Source.Commanded(s.output));
            end
        end

        % ---- Signals ---------------------------------------------------------

        function value = latest(obj, signal)
            % The newest value of a signal, or NaN if there isn't one yet.
            [~, y] = obj.history(signal);
            value = NaN;
            if ~isempty(y)
                value = y(end);
            end
        end

        function [t, y] = history(obj, signal)
            % The last PlotSeconds of a signal: t in seconds (0 is the
            % newest sample, older ones negative), y its values. Both empty
            % if there's nothing yet.
            signal = string(signal);
            tel = obj.Telemetry;
            k = find(lower([obj.Servos.name]) == lower(signal), 1);
            if lower(signal) == "pitch" || lower(signal) == "pitch rate"
                [t, v] = tel.Pitch.data();
                y = v(:, 1 + 2 * (lower(signal) == "pitch rate"));   % column 1 or 3
            elseif ~isempty(regexp(lower(signal), "^rc([1-9]|1[0-8])$", "once"))
                % A transmitter channel, as the Cube receives it (us).
                [t, pwm] = tel.Rc.data();
                y = pwm(:, str2double(extractAfter(lower(signal), 2)));
            elseif ~isempty(k)
                % A servo: the PWM the Cube reports, in the servo's units.
                % 0 means it's sending no pulses, so leave a gap.
                s = obj.Servos(k);
                [t, pwm] = tel.Outputs.data();
                pwm = pwm(:, s.output);
                y = s.mapping.toValue(pwm);
                y(pwm == 0) = NaN;
            else
                buffer = tel.namedHistory(signal);   % a value from a Lua script
                if isempty(buffer)
                    t = zeros(0, 1);
                    y = zeros(0, 1);
                    return
                end
                [t, y] = buffer.data();
            end
            if ~isempty(t)
                keep = t >= t(end) - obj.PlotSeconds;
                t = t(keep) - t(end);
                y = y(keep);
            end
        end

        function text = units(obj, signal)
            % A signal's units, for labels: "deg", "deg/s", a servo's units,
            % or "" for a Lua value (its script decides).
            signal = lower(string(signal));
            k = find(lower([obj.Servos.name]) == signal, 1);
            if signal == "pitch"
                text = "deg";
            elseif signal == "pitch rate"
                text = "deg/s";
            elseif ~isempty(regexp(signal, "^rc([1-9]|1[0-8])$", "once"))
                text = "us";
            elseif ~isempty(k)
                text = obj.Servos(k).mapping.Units;
            else
                text = "";
            end
        end

        % ---- Who's in charge (level 2 on, with lua/cubegui.lua) -----------------

        function m = mode(obj)
            % Who's in charge of the servos, as a struct:
            %   name       "CubeGUI", "Transmitter (RC)" or "Closed loop"
            %   code       0, 1 or 2 (CG_MODE), or NaN without the script
            %   script     true if the Cube's script is reporting
            %   rc         true if the Cube has a valid transmitter signal
            %   sas        true if stability augmentation is on
            %   target     the closed loop's pitch target (degrees), as the script reports it
            %   requested  what CubeGUI has asked for: "CubeGUI" or "Closed loop"
            % Heard recently, and with a mode it knows (0, 1 or 2): a value
            % can be missing just after the telemetry has been cleared.
            code = round(obj.latest("CG_MODE"));
            script = obj.Telemetry.secondsSinceNamed("CG_MODE") < obj.ScriptTimeout ...
                && ismember(code, [0 1 2]);
            m = struct("name", "CubeGUI", "code", NaN, "script", script, "rc", false, ...
                "sas", false, "target", NaN, "requested", obj.ModeNames(obj.Requested.mode + 1));
            if script
                m.code = code;
                m.name = obj.ModeNames(code + 1);
                m.rc = obj.latest("CG_RC") > 0.5;
                m.sas = obj.latest("CG_SAS") > 0.5;
                m.target = obj.latest("CG_TGT");
            end
        end

        function requestMode(obj, name)
            % Ask the Cube's script for a mode: "gui" (CubeGUI drives) or
            % "closed loop" (the script holds the pitch at the target). A
            % transmitter switch, if there is one, can overrule this.
            switch lower(strrep(string(name), " ", ""))
                case {"gui", "cubegui"}
                    obj.Requested.mode = 0;
                case "closedloop"
                    obj.Requested.mode = 2;
                otherwise
                    error("CubeGUI:mode", "requestMode takes ""gui"" or ""closed loop"", not ""%s"".", name)
            end
            obj.sendRequest();
        end

        function setPitchTarget(obj, degrees)
            % The closed loop's pitch target, in degrees (nose up positive),
            % held within +-45. Sent at most 10 times a second.
            obj.Requested.target = max(-45, min(45, degrees));
            obj.RequestPending = true;
        end

        function setSas(obj, on)
            % Stability augmentation on or off. A transmitter SAS switch, if
            % there is one, overrules this.
            obj.Requested.sas = logical(on);
            obj.sendRequest();
        end

        function mark(obj, text)
            % A run marker, e.g. "run 3 start". It goes in CubeGUI's log (the
            % marker column) and the Cube's own log (as a MSG), so the two
            % can be lined up afterwards.
            text = strtrim(string(text));
            if text == ""
                return
            end
            obj.Telemetry.addMarker(text);
            if ~isempty(obj.Source)
                obj.Source.sendText("CubeGUI: " + text);
            end
            obj.say("Marked: " + text);
        end

        % ---- Everything else -------------------------------------------------

        function tf = isConnected(obj)
            tf = ~isempty(obj.Source);
        end

        function say(obj, text, isProblem)
            % Put a message in the status line at the bottom of the window.
            % say(text, true) shows it in red, as a problem.
            if nargin < 3
                isProblem = false;
            end
            obj.Say(string(text), isProblem);
        end
    end

    % ======================================================================
    % For the window and the tests only, so hidden from panels: they don't
    % appear in methods(cube) or in tab completion.
    methods (Hidden)
        function attach(obj, source)
            % A source has connected. Servos switch on as its limits arrive.
            obj.Source = source;
            obj.LimitsParamCount = -1;
            for k = 1:numel(obj.Servos)
                obj.Servos(k).limits = NaN(1, 3);
                obj.Servos(k).target = NaN;
                obj.Servos(k).pending = NaN;
                obj.Servos(k).scriptWhy = "";
            end
            obj.updateLimits();
            % From level 2, start with CubeGUI in charge, and tell the script so.
            obj.Requested = struct("mode", 0, "target", 0, "sas", false);
            if obj.Level >= 2
                obj.sendRequest();
            end
        end

        function detach(obj)
            % The source has disconnected: switch every servo off.
            obj.Source = [];
            for k = 1:numel(obj.Servos)
                obj.Servos(k).ready = false;
                obj.Servos(k).why = "Connect to use this servo.";
                obj.Servos(k).pending = NaN;
            end
        end

        function tick(obj)
            % Called by the window's redraw timer, 10 times a second.
            obj.updateLimits();
            % From level 2: send a held-back request, and repeat the current
            % one once a second, so a message lost on the Wi-Fi is soon made good.
            if obj.Level >= 2 && ~isempty(obj.Source)
                sinceLast = Inf;
                if obj.LastRequestSend ~= 0
                    sinceLast = toc(obj.LastRequestSend);
                end
                if (obj.RequestPending && sinceLast >= obj.SendInterval) || sinceLast >= 1
                    obj.sendRequest();
                end
            elseif ~isempty(obj.Source)
                % Below level 2 the window has no mode controls. So if the
                % Cube's script is still in closed loop (left there from a
                % higher level), ask it to hand the elevator back, once a second.
                m = obj.mode();
                if m.script && m.code == 2 && (obj.LastRequestSend == 0 || toc(obj.LastRequestSend) >= 1)
                    obj.Requested.mode = 0;
                    obj.sendRequest();
                    obj.say("The Cube's script was in closed loop: asking it to hand the " + ...
                        "elevator back to CubeGUI.");
                end
            end
            obj.followScript();
            for k = 1:numel(obj.Servos)
                s = obj.Servos(k);
                if ~isnan(s.pending) && obj.usable(k) && toc(s.lastSend) >= obj.SendInterval
                    obj.Servos(k).pending = NaN;
                    obj.send(k, s.mapping.toPwm(s.pending));
                end
            end
        end

        function pwm = sendNow(obj, name, value)
            % Send straight away, skipping the 10-a-second limit, and return
            % the PWM sent (NaN if nothing went). For the tests, which send
            % several commands in quick succession.
            k = obj.find(name);
            s = obj.Servos(k);
            value = min(max(value, s.mapping.Range(1)), s.mapping.Range(2));
            obj.Servos(k).target = value;
            pwm = NaN;
            if obj.usable(k)
                pwm = obj.send(k, s.mapping.toPwm(value));
            else
                obj.say(obj.whyNot(k), true);
            end
        end
    end

    methods (Access = private)
        function k = find(obj, name)
            k = find(lower([obj.Servos.name]) == lower(string(name)), 1);
            if isempty(k)
                error("CubeGUI:servo", "There's no servo called ""%s"" in the settings. " + ...
                    "The servos are: %s.", name, strjoin([obj.Servos.name], ", "))
            end
        end

        function pwm = send(obj, k, pwm)
            % Send PWM to servo k through DataSource.setServo, which clamps it.
            obj.Servos(k).lastSend = tic;
            try
                pwm = obj.Source.setServo(obj.Servos(k).output, pwm);
            catch err
                pwm = NaN;
                obj.say(err.message, true);
            end
        end

        function text = whyNot(obj, k)
            [~, why] = obj.usable(k);
            if isempty(obj.Source)
                text = "Not connected, so nothing was sent. Click Connect first.";
            else
                text = sprintf("The %s isn't ready: %s", lower(obj.Servos(k).name), why);
            end
        end

        function [tf, why] = usable(obj, k)
            % Can CubeGUI drive servo k now? If not, why not.
            s = obj.Servos(k);
            why = "";
            if isempty(obj.Source)
                why = "Connect to use this servo.";
            elseif ~s.ready
                why = s.why;
            else
                why = obj.scriptDrives(s.output);
            end
            tf = why == "";
        end

        function why = scriptDrives(obj, output)
            % "" unless the Cube's script is driving this output, in which
            % case the Cube ignores CubeGUI's commands to it. Which outputs
            % it drives comes from its parameters (CGUI_ELEV_OUT, CGUI_Mn_OUT).
            why = "";
            m = obj.mode();
            if ~m.script
                return
            end
            tel = obj.Telemetry;
            if m.code == 2 && output == valueOr(tel.param("CGUI_ELEV_OUT"), 5)
                why = "the closed loop is driving it.";
            elseif m.code == 1
                defaults = [2 5; 4 6; 0 0; 0 0];   % the script's defaults: stick, output
                for n = 1:4
                    stick = valueOr(tel.param("CGUI_M" + n + "_RC"), defaults(n, 1));
                    out = valueOr(tel.param("CGUI_M" + n + "_OUT"), defaults(n, 2));
                    if stick > 0 && out == output
                        why = "the transmitter is driving it (RC mode).";
                    end
                end
            end
        end

        function followScript(obj)
            % When the script hands a servo back to CubeGUI, move its target
            % to where the servo actually is, so the slider catches up with
            % the servo rather than the servo jumping back to the slider.
            for k = 1:numel(obj.Servos)
                why = obj.scriptDrives(obj.Servos(k).output);
                if obj.Servos(k).scriptWhy ~= "" && why == ""
                    obj.Servos(k).target = obj.latest(obj.Servos(k).name);
                    obj.Servos(k).pending = NaN;
                end
                obj.Servos(k).scriptWhy = why;
            end
        end

        function sendRequest(obj)
            % Send CubeGUI's request to the Cube's script.
            obj.RequestPending = false;
            if isempty(obj.Source)
                return
            end
            obj.LastRequestSend = tic;
            r = obj.Requested;
            try
                obj.Source.sendScriptCommand(r.mode, r.target, r.sas);
            catch err
                obj.say(err.message, true);
            end
        end

        function updateLimits(obj)
            % Give each servo the Cube's SERVOn_MIN, _TRIM and _MAX, once
            % they've arrived, and again whenever they change (after a write
            % in the Setup tab, say). Limits outside 1000 to 2000 us are
            % refused: that servo is switched off until they're fixed. The
            % Cube doesn't hold DO_SET_SERVO to its limits itself (checked
            % in ArduPilot's AP_ServoRelayEvents.cpp and SRV_Channel.cpp).
            tel = obj.Telemetry;
            if isempty(obj.Source) || tel.ParamCount == obj.LimitsParamCount
                return   % not connected, or no parameter has arrived since last time
            end
            obj.LimitsParamCount = tel.ParamCount;
            for k = 1:numel(obj.Servos)
                n = obj.Servos(k).output;
                limits = [tel.param("SERVO" + n + "_MIN"), tel.param("SERVO" + n + "_TRIM"), ...
                    tel.param("SERVO" + n + "_MAX")];
                if isequaln(limits, obj.Servos(k).limits)
                    continue   % nothing new
                end
                obj.Servos(k).limits = limits;
                problem = DataSource.limitsProblem(limits(1), limits(2), limits(3));
                if problem == ""
                    % Build the mapping again from these limits: a PWM slider
                    % runs from MIN to MAX, and percent is 0 % at TRIM and
                    % +-100 % at MAX and MIN.
                    s = obj.Servos(k).settings;
                    s.minPwm = limits(1);
                    s.trimPwm = limits(2);
                    s.maxPwm = limits(3);
                    s.mapping = s.mappingSettings;
                    obj.Servos(k).mapping = ServoMapping(s);
                    obj.Source.setServoLimits(n, limits(1), limits(3));
                    obj.Servos(k).ready = true;
                    obj.Servos(k).why = "";
                elseif any(isnan(limits))
                    obj.Source.clearServoLimits(n);
                    obj.Servos(k).ready = false;
                    obj.Servos(k).why = "waiting for its limits from the Cube.";
                else
                    obj.Source.clearServoLimits(n);
                    obj.Servos(k).ready = false;
                    obj.Servos(k).why = "its limits on the Cube need fixing.";
                    obj.say(sprintf(['CubeGUI won''t drive the %s: on the Cube, its %s. ' ...
                        'Fix SERVO%d_MIN, _TRIM and _MAX in the Setup tab.'], ...
                        lower(obj.Servos(k).name), problem, n), true);
                end
            end
        end
    end
end

function value = valueOr(value, fallback)
% value, or fallback if value is NaN (a parameter that hasn't arrived).
if isnan(value)
    value = fallback;
end
end
