classdef Telemetry < handle
    %TELEMETRY  The latest data from the Cube (or the simulation), in one place.
    %
    %   Data sources put things in; the window and the logger read them out.
    %   Message callbacks call the add... methods, which only store data, so
    %   they're quick and never touch the window.
    %
    %   Times are the Cube's own clock, in seconds since it booted, so plots
    %   are as smooth as the Cube's sampling whatever the Wi-Fi does. Each
    %   pitch sample also records the laptop's clock when it arrived, so the
    %   log can be lined up with other systems (such as the tunnel's) later.

    properties (SetAccess = private)
        Pitch            % RingBuffer: Cube time (s); pitch (deg), laptop time on arrival (POSIX s), pitch rate (deg/s)
        Outputs          % RingBuffer: Cube time (s); PWM on outputs 1 to 16 (us)
        Commands         % RingBuffer: laptop time (POSIX s); output number, PWM sent (us)
        Rc               % RingBuffer: Cube time (s); the transmitter's channels 1 to 18 (us, 0 or 65535: none)
        Markers = struct("time", {}, "text", {})   % run markers: laptop time (POSIX s), text
        HeartbeatCount = 0
        AckCount = 0     % how many command replies (COMMAND_ACK) have arrived
        LastAck = struct("command", NaN, "result", NaN)
        VehicleType = NaN    % MAV_TYPE from the heartbeat: 1 is a fixed-wing (ArduPlane)
        Params               % parameter values from the Cube, by name (a dictionary)
        ParamCount = 0       % goes up each time a parameter value arrives
        Version = []         % what AUTOPILOT_VERSION said, as a struct, or [] until it arrives
        NamedValues          % latest values from Lua scripts (NAMED_VALUE_FLOAT), by name
        SafetyOn = NaN       % true: safety switch on (servos held); false: off; NaN: not known yet
        RebootCount = 0      % how many times the Cube has rebooted while connected
        LateCount = 0        % samples skipped because they arrived late, out of order
    end

    properties (Access = private)
        StartPosix              % laptop clock (UTC, POSIX seconds) when created...
        StartTic                % ...and the matching tic, for cheap clock readings
        LastHeartbeatTic = []   % laptop time of the last heartbeat, from tic
        LastSafetyTic = []      % laptop time the safety state was last reported
        LastPitchTime = NaN     % Cube time of the newest pitch sample held (s)
        LastOutputsTime = NaN   % Cube time of the newest output sample held (s)
        BehindSinceTic = []     % when pitch samples started arriving well behind, from tic
        NamedHistory            % a RingBuffer of each Lua value, by name (a containers.Map)
        NamedArrived            % laptop time each Lua value last arrived, by name (a dictionary)
        LastRcTime = NaN        % Cube time of the newest RC sample held (s)
        Capacity                % samples each history holds
    end

    methods
        function obj = Telemetry(plotSeconds, rateHz)
            % Room for the whole plot window at twice the expected rate.
            capacity = ceil(plotSeconds * rateHz * 2);
            obj.Capacity = capacity;
            obj.Pitch = RingBuffer(capacity, 3);
            obj.Outputs = RingBuffer(capacity, 16);
            obj.Commands = RingBuffer(2000, 2);
            obj.Rc = RingBuffer(capacity, 18);
            obj.StartPosix = posixtime(datetime("now", TimeZone="UTC"));
            obj.StartTic = tic;
            obj.resetDictionaries();
        end

        function t = laptopTime(obj)
            % The laptop's clock as UTC POSIX seconds (seconds since 1 Jan
            % 1970), to the millisecond. Reading datetime("now") in every
            % message callback would be slower, so this counts on from a
            % single reading taken when the object was made.
            t = obj.StartPosix + toc(obj.StartTic);
        end

        function addHeartbeat(obj, vehicleType)
            obj.LastHeartbeatTic = tic;
            obj.HeartbeatCount = obj.HeartbeatCount + 1;
            if nargin > 1
                obj.VehicleType = vehicleType;
            end
        end

        function addParam(obj, name, value)
            % A dictionary is like a Python dict: Params("THR_FAILSAFE") gives the value.
            obj.Params(string(name)) = value;
            obj.ParamCount = obj.ParamCount + 1;
        end

        function value = param(obj, name)
            % A parameter's value, or NaN if it hasn't arrived.
            if isKey(obj.Params, name)
                value = obj.Params(name);
            else
                value = NaN;
            end
        end

        function forgetParams(obj, names)
            % Drop these parameters, so the Setup tab shows them as being read again.
            for name = string(names)
                if isKey(obj.Params, name)
                    obj.Params(name) = [];
                end
            end
            obj.ParamCount = obj.ParamCount + 1;
        end

        function setVersion(obj, info)
            obj.Version = info;
        end

        function addSysStatus(obj, sensorsEnabled)
            % SYS_STATUS says which of the Cube's systems are switched on.
            % ArduPilot marks "motor outputs" (bit 32768) as on whenever
            % the safety switch is off, so that bit tells us the switch's
            % state. (Checked in ArduPilot's source, GCS.cpp.)
            obj.setSafety(bitand(uint32(sensorsEnabled), uint32(32768)) == 0);
        end

        function setSafety(obj, isOn)
            obj.SafetyOn = isOn;
            obj.LastSafetyTic = tic;
        end

        function s = secondsSinceSafety(obj)
            if isempty(obj.LastSafetyTic)
                s = Inf;
            else
                s = toc(obj.LastSafetyTic);
            end
        end

        function addNamedValue(obj, name, value, t)
            % A value a Lua script sent with gcs:send_named_float(name, value).
            % t is the Cube's clock (s) when it was sent, kept so the value
            % can be plotted like any other signal.
            name = string(name);
            obj.NamedValues(name) = value;
            obj.NamedArrived(name) = obj.laptopTime();
            if nargin < 4
                return
            end
            if ~isKey(obj.NamedHistory, char(name))
                obj.NamedHistory(char(name)) = RingBuffer(obj.Capacity, 1);
            end
            buffer = obj.NamedHistory(char(name));
            [times, ~] = buffer.data();
            if isempty(times) || t > times(end)   % skip late or repeated ones
                buffer.push(t, value);
            end
        end

        function s = secondsSinceNamed(obj, name)
            % How long since a Lua value last arrived, or Inf if it never has.
            s = Inf;
            if isKey(obj.NamedArrived, string(name))
                s = obj.laptopTime() - obj.NamedArrived(string(name));
            end
        end

        function addRc(obj, t, pwm)
            % RC_CHANNELS: what the Cube receives from the transmitter.
            if t <= obj.LastRcTime
                return   % late or repeated
            end
            obj.LastRcTime = t;
            obj.Rc.push(t, pwm);
        end

        function addMarker(obj, text)
            % A run marker, e.g. "run 3 start", stamped with the laptop's clock.
            obj.Markers(end+1) = struct("time", obj.laptopTime(), "text", string(text));
        end

        function buffer = namedHistory(obj, name)
            % The RingBuffer of one Lua value, or [] if it hasn't arrived.
            buffer = [];
            if isKey(obj.NamedHistory, char(name))
                buffer = obj.NamedHistory(char(name));
            end
        end

        function s = secondsSinceHeartbeat(obj)
            % Inf if no heartbeat has arrived yet.
            if isempty(obj.LastHeartbeatTic)
                s = Inf;
            else
                s = toc(obj.LastHeartbeatTic);
            end
        end

        function addPitch(obj, t, pitchDeg, pitchRateDeg)
            % pitchRateDeg: how fast the pitch is changing (deg/s), if known.
            if nargin < 4
                pitchRateDeg = NaN;
            end
            % Samples must go into the buffer in time order. One that's
            % older than the newest held was either held up on the way, or
            % the Cube has rebooted (see looksLikeReboot).
            if ~isnan(obj.LastPitchTime) && t <= obj.LastPitchTime
                if ~obj.looksLikeReboot(t)
                    obj.LateCount = obj.LateCount + 1;   % late: skip it
                    return
                end
                obj.startAgainAfterReboot();
            end
            obj.BehindSinceTic = [];
            obj.LastPitchTime = t;
            obj.Pitch.push(t, [pitchDeg, obj.laptopTime(), pitchRateDeg]);
        end

        function addCommand(obj, output, pwm)
            % Called by DataSource.setServo, so the log can show what was sent.
            obj.Commands.push(obj.laptopTime(), [output, pwm]);
        end

        function addOutputsUsec(obj, rawUsec, pwm)
            % SERVO_OUTPUT_RAW's clock counts microseconds in a 32-bit number,
            % so it wraps back to 0 every 71.6 minutes (2^32 us). ArduPilot
            % fills it from AP_HAL::micros() (GCS_Common.cpp,
            % send_servo_output_raw). The pitch clock counts milliseconds
            % and only wraps after 49 days, and the two read within a
            % fraction of a second of each other. So the pitch clock says
            % how many times the output clock has wrapped, even if the Cube
            % had been on for over 71.6 minutes before CubeGUI connected
            % (it had, in testing on 2026-10-23).
            wrapSeconds = 2^32 / 1e6;
            t = rawUsec / 1e6;
            if ~isnan(obj.LastPitchTime)
                wraps = round((obj.LastPitchTime - t) / wrapSeconds);
                % Only if that brings the two clocks together. Just after a
                % reboot they can disagree for a moment; then leave t alone.
                if wraps > 0 && abs(t + wraps * wrapSeconds - obj.LastPitchTime) < 60
                    t = t + wraps * wrapSeconds;
                end
            end
            % Late or repeated: skip it. (A reboot empties this buffer, in
            % startAgainAfterReboot, so a rebooted Cube's samples go in.)
            if t <= obj.LastOutputsTime
                obj.LateCount = obj.LateCount + 1;
                return
            end
            obj.LastOutputsTime = t;
            obj.Outputs.push(t, pwm);
        end

        function addAck(obj, command, result)
            obj.LastAck = struct("command", command, "result", result);
            obj.AckCount = obj.AckCount + 1;
        end

        function clear(obj)
            % Start afresh, e.g. on a new connection.
            obj.Pitch.clear();
            obj.Outputs.clear();
            obj.Commands.clear();
            obj.HeartbeatCount = 0;
            obj.LastHeartbeatTic = [];
            obj.AckCount = 0;
            obj.LastAck = struct("command", NaN, "result", NaN);
            obj.LastPitchTime = NaN;
            obj.LastOutputsTime = NaN;
            obj.BehindSinceTic = [];
            obj.LateCount = 0;
            obj.Rc.clear();
            obj.LastRcTime = NaN;
            obj.Markers = obj.Markers([]);
            obj.VehicleType = NaN;
            obj.SafetyOn = NaN;
            obj.LastSafetyTic = [];
            obj.ParamCount = 0;
            obj.Version = [];
            obj.RebootCount = 0;
            obj.resetDictionaries();
        end
    end

    methods (Access = private)
        function resetDictionaries(obj)
            obj.Params = dictionary(string.empty, double.empty);
            obj.NamedValues = dictionary(string.empty, double.empty);
            obj.NamedHistory = containers.Map(KeyType="char", ValueType="any");
            obj.NamedArrived = dictionary(string.empty, double.empty);
        end

        function tf = looksLikeReboot(obj, t)
            % The Cube's clock has gone backwards to t. Either the Cube has
            % rebooted (its clock starts again from 0), or this sample was
            % held up on the way: Wi-Fi can deliver messages late and out of
            % order (seen on 2026-10-23, up to 7 s late). Call it a reboot if
            % the clock is more than a second back and either
            %   - the Cube's clock is under a minute (it has just started), or
            %   - samples have kept arriving well behind for 3 s, with none
            %     catching up (a long-running Cube that rebooted unseen).
            tf = false;
            if t > obj.LastPitchTime - 1
                return
            end
            if isempty(obj.BehindSinceTic)
                obj.BehindSinceTic = tic;
            end
            tf = t < 60 || toc(obj.BehindSinceTic) > 3;
        end

        function startAgainAfterReboot(obj)
            % Drop the old samples, which would confuse the plots and the
            % log. Forget the version too, so it's asked for again: the
            % firmware may have been re-flashed.
            obj.Pitch.clear();
            obj.Outputs.clear();
            obj.Rc.clear();
            obj.LastRcTime = NaN;
            for buffer = values(obj.NamedHistory)
                buffer{1}.clear();
            end
            obj.LastPitchTime = NaN;
            obj.LastOutputsTime = NaN;
            obj.RebootCount = obj.RebootCount + 1;
            obj.Version = [];
        end
    end
end
