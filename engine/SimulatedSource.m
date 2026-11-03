classdef SimulatedSource < DataSource
    %SIMULATEDSOURCE  A pretend Cube inside MATLAB, needing no network or toolbox.
    %
    %   The fuselage swings gently in pitch, and servo commands come back as
    %   outputs straight away. The elevator output also nudges the pitch, so
    %   moving the elevator slider visibly does something. Use it to try
    %   CubeGUI before the kit is wired up, or in MATLAB Online.
    %
    %   It also behaves as if lua/cubegui.lua were on the Cube, once CubeGUI
    %   has sent it a command (from level 2): it reports CG_MODE and the
    %   rest, and in closed-loop mode runs the same PID, with the same CGUI_
    %   parameters, on the simulated pitch. Its gains are tuned for this
    %   simulation, not for the real rig. There's no transmitter, so no RC mode.

    properties
        ElevatorOutput = 5   % the output whose PWM nudges the simulated pitch
    end

    properties (Constant, Access = private)
        RateHz = 20
        SwingDeg = 5             % size of the swing
        SwingPeriod = 4          % seconds per swing
        NoiseDeg = 0.2
        DegPerUsec = 0.02        % pitch change per us of elevator away from trim
        ResponseTime = 0.5       % seconds for the pitch to follow the elevator
    end

    properties (Access = private)
        Timer
        StartTic
        NextHeartbeat = 0
        Outputs = 1500 * ones(1, 16)
        PitchOffset = 0
        Params          % the simulated Cube's parameters (a dictionary)
        DefaultParams   % what they start as, and go back to after a reset
        SafetyOn = true % like a real Cube after a reboot: servos held
        % The pretend cubegui.lua
        ScriptHeard = false   % true once CubeGUI has sent it a command
        ScriptMode = 0        % 0 CubeGUI drives, 2 closed loop
        ScriptTarget = 0      % pitch target, degrees
        ScriptSas = false
        Integral = 0          % the PID's I term, us
        LastPitch = 0         % the last simulated pitch and rate, for the PID
        LastRate = 0
        StepCount = 0
    end

    methods
        function obj = SimulatedSource(telemetry)
            obj.Telemetry = telemetry;
            % A Cube in the state the AVDASI 2 guide leaves it: ArduPlane
            % defaults, with THR_FAILSAFE set to 0. Outputs 1 to 4 belong to
            % ArduPlane's own controls; the rest are free (function 0).
            % FORMAT_VERSION is ArduPlane's 13 (ArduPlane/Parameters.h).
            p = dictionary(["THR_FAILSAFE", "SCR_ENABLE", "LOG_DISARMED", "BRD_SAFETY_DEFLT", ...
                "BRD_SAFETY_MASK", "ARMING_CHECK", "SERIAL1_PROTOCOL", "SERIAL1_BAUD", ...
                "FORMAT_VERSION"], [0, 0, 0, 1, 0, 1, 2, 57, 13]);
            functions = [4 19 70 21 zeros(1, 12)];
            for n = 1:16
                p("SERVO" + n + "_FUNCTION") = functions(n);
                p("SERVO" + n + "_MIN") = 1100;
                p("SERVO" + n + "_TRIM") = 1500;
                p("SERVO" + n + "_MAX") = 1900;
                p("SERVO" + n + "_REVERSED") = 0;
            end
            % No STEST_ parameters: servo_slew.lua isn't "installed", so the
            % Setup tab shows them as not on this Cube, as it would for real.
            % cubegui.lua's parameters, as if it were installed, with gains
            % that suit this simulation.
            names = ["CGUI_ENABLE", "CGUI_ELEV_OUT", "CGUI_MODE_FUNC", "CGUI_SAS_FUNC", "CGUI_KP", ...
                "CGUI_KI", "CGUI_KD", "CGUI_IMAX", "CGUI_SAS_KD", "CGUI_M1_RC", "CGUI_M1_OUT", ...
                "CGUI_M2_RC", "CGUI_M2_OUT", "CGUI_M3_RC", "CGUI_M3_OUT", "CGUI_M4_RC", "CGUI_M4_OUT"];
            values = [1, 5, 300, 301, 50, 50, 2, 300, 3, 2, 5, 4, 6, 0, 0, 0, 0];
            for k = 1:numel(names)
                p(names(k)) = values(k);
            end
            obj.Params = p;
            obj.DefaultParams = p;
        end

        function connect(obj)
            if obj.IsConnected
                return
            end
            obj.StartTic = tic;
            obj.NextHeartbeat = 0;
            obj.Timer = timer(ExecutionMode="fixedRate", Period=1 / obj.RateHz, ...
                BusyMode="drop", Name="CubeGUI simulated source", ...
                TimerFcn=@(~, ~) obj.step());
            start(obj.Timer)
            obj.IsConnected = true;
            obj.Telemetry.setVersion(struct("firmware", "Simulated (no Cube)", ...
                "git", "", "board", "", "uid", ""));
        end

        function disconnect(obj)
            if ~isempty(obj.Timer) && isvalid(obj.Timer)
                stop(obj.Timer)
                delete(obj.Timer)
            end
            obj.Timer = [];
            obj.IsConnected = false;
        end

        function text = describe(~)
            text = "Simulated";
        end

        function requestParams(obj, names)
            for name = string(names)
                if isKey(obj.Params, name)
                    obj.Telemetry.addParam(name, obj.Params(name));
                end
            end
        end

        function setParam(obj, name, value)
            if ~isKey(obj.Params, string(name))
                return   % a real Cube ignores parameters it doesn't have
            end
            obj.Params(string(name)) = value;
            obj.Telemetry.addParam(name, value);   % a real Cube echoes the new value
        end

        function setSafety(obj, on)
            obj.SafetyOn = on;
            obj.Telemetry.setSafety(on);
        end

        function sendScriptCommand(obj, mode, targetDeg, sas)
            obj.ScriptHeard = true;
            newMode = 0;
            if round(mode) == 2
                newMode = 2;
            end
            if newMode ~= obj.ScriptMode
                obj.Integral = 0;   % start the controller afresh, as the script does
            end
            obj.ScriptMode = newMode;
            obj.ScriptTarget = max(-45, min(45, targetDeg));
            obj.ScriptSas = sas;
        end

        function sendText(~, ~)
            % A real Cube writes it into its log; there's no log here.
        end

        function reboot(obj)
            % Like a real Cube: its clock starts again from zero (which is
            % how CubeGUI notices), the safety switch is on, and the pretend
            % script starts afresh.
            obj.StartTic = tic;
            obj.NextHeartbeat = 0;   % its heartbeats follow the new clock
            % FORMAT_VERSION 0 at start-up erases every setting, as ArduPilot
            % does (AP_Vehicle/Parameters.cpp, load_parameters).
            if obj.Params("FORMAT_VERSION") ~= obj.DefaultParams("FORMAT_VERSION")
                obj.Params = obj.DefaultParams;
            end
            obj.SafetyOn = true;
            obj.ScriptHeard = false;
            obj.ScriptMode = 0;
            obj.Integral = 0;
        end
    end

    methods (Access = protected)
        function sendServo(obj, output, pwm)
            % While the pretend script's closed loop drives the elevator, the
            % Cube ignores CubeGUI's commands to it, as a real one does.
            if ~obj.closedLoopDrives(output)
                obj.Outputs(output) = pwm;
            end
        end
    end

    methods (Access = private)
        function step(obj)
            % One tick of the simulation: what a real Cube would send 20 times a second.
            try
                t = toc(obj.StartTic);
                if t >= obj.NextHeartbeat
                    obj.Telemetry.addHeartbeat(1);   % 1: fixed-wing, like ArduPlane
                    obj.Telemetry.setSafety(obj.SafetyOn);
                    % A pretend Lua value, as gcs:send_named_float("DEMO", x) would send.
                    obj.Telemetry.addNamedValue("DEMO", round(1.65 + 0.5 * sin(2 * pi * t / 10), 3), t);
                    obj.NextHeartbeat = obj.NextHeartbeat + 1;
                end

                obj.runScript();

                % Pitch follows the elevator gradually, plus a swing and some
                % noise. With the safety switch on, the servo is held still,
                % so the elevator does nothing, as on the real rig.
                target = 0;
                if ~obj.SafetyOn
                    target = obj.DegPerUsec * (obj.Outputs(obj.ElevatorOutput) - 1500);
                end
                offsetRate = (target - obj.PitchOffset) / obj.ResponseTime;   % deg/s
                obj.PitchOffset = obj.PitchOffset + offsetRate / obj.RateHz;
                w = 2 * pi / obj.SwingPeriod;
                pitch = obj.PitchOffset + obj.SwingDeg * sin(w * t) + obj.NoiseDeg * randn();
                pitchRate = offsetRate + obj.SwingDeg * w * cos(w * t);       % deg/s

                obj.LastPitch = pitch;
                obj.LastRate = pitchRate;
                obj.Telemetry.addPitch(t, pitch, pitchRate);
                obj.Telemetry.addOutputsUsec(round(t * 1e6), obj.Outputs);
            catch err
                fprintf(2, "Simulated source: %s\n", err.message);
            end
        end

        function tf = closedLoopDrives(obj, output)
            tf = obj.ScriptMode == 2 && obj.Params("CGUI_ENABLE") >= 0.5 ...
                && output == obj.Params("CGUI_ELEV_OUT");
        end

        function runScript(obj)
            % What lua/cubegui.lua does each time it runs, less RC.
            obj.StepCount = obj.StepCount + 1;
            if ~obj.ScriptHeard
                return
            end
            p = obj.Params;
            mode = obj.ScriptMode;
            if p("CGUI_ENABLE") < 0.5
                mode = 0;
            end
            elevPwm = 0;
            if mode == 2
                % The same PID as the script: P and I on the pitch error,
                % D opposing the pitch rate, all in us of elevator.
                dt = 1 / obj.RateHz;
                err = obj.ScriptTarget - obj.LastPitch;
                limit = p("CGUI_IMAX");
                obj.Integral = max(-limit, min(limit, obj.Integral + p("CGUI_KI") * err * dt));
                offset = p("CGUI_KP") * err + obj.Integral - p("CGUI_KD") * obj.LastRate;
                out = p("CGUI_ELEV_OUT");
                n = string(out);
                direction = 1 - 2 * (p("SERVO" + n + "_REVERSED") > 0.5);
                pwm = p("SERVO" + n + "_TRIM") + direction * offset;
                elevPwm = round(max(p("SERVO" + n + "_MIN"), min(p("SERVO" + n + "_MAX"), pwm)));
                obj.Outputs(out) = elevPwm;
            end
            if mod(obj.StepCount, 4) == 0      % 5 times a second, like the script
                t = toc(obj.StartTic);
                tel = obj.Telemetry;
                tel.addNamedValue("CG_MODE", mode, t);
                tel.addNamedValue("CG_SAS", double(obj.ScriptSas), t);
                tel.addNamedValue("CG_TGT", obj.ScriptTarget, t);
                tel.addNamedValue("CG_RC", 0, t);   % no transmitter in the simulation
                tel.addNamedValue("CG_ELEV", elevPwm, t);
            end
        end
    end
end
