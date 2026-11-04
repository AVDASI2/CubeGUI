classdef CubeSource < DataSource
    %CUBESOURCE  A real Cube (or tools/fake_cube.py), over MAVLink on UDP or USB.
    %
    %   This is the one place that owns the connection. It does what
    %   scripts/step2 to step4 did, packaged up: listen on a UDP port, send a
    %   heartbeat every second, ask for 20 Hz telemetry, store what arrives,
    %   and send servo commands.
    %
    %   Needs desktop MATLAB with UAV Toolbox, on a laptop joined to the
    %   kit's Wi-Fi. Works on R2026a and later.
    %
    %   It can use a USB cable instead (a serial port, such as
    %   COM3 on Windows or /dev/cu.usbmodem... on a Mac): give the port's
    %   name as the sixth argument. UAV Toolbox can only do MAVLink over a
    %   serial port from R2026b.

    properties (SetAccess = private)
        LocalPort
        CubeAddress
        CubePort
        RateHz
        SerialPort = ""     % the USB port's name, or "" for the Wi-Fi (UDP)
        Logs                % a LogDownload, for fetching the Cube's own logs
        Upload              % an FtpUpload, for copying cubegui.lua onto the Cube
    end

    properties
        % Where the Cube runs Lua scripts from. ArduPilot's SITL keeps them
        % in "scripts" in its own folder instead (tools/sitl sets this).
        ScriptFolder = "/APM/scripts"
    end

    properties (Constant, Access = private)
        SubscriptionBuffer = 200   % messages each subscription can hold (see connect)
        SerialBaud = 115200        % the USB port's speed (ArduPilot ignores it on USB)
        LogDataBuffer = 2000       % LOG_DATA comes in bursts while a log downloads
    end

    properties (Access = private)
        Dialect
        Io
        Subscriptions = {}
        Timer
        Heartbeat           % our HEARTBEAT message, ready to send
        RateRequests        % SET_MESSAGE_INTERVAL commands, each with a check for "too slow"
        ServoCommand        % a DO_SET_SERVO command to fill in and send
        VersionRequest      % REQUEST_MESSAGE for AUTOPILOT_VERSION
        SafetyWanted = NaN  % the safety state asked for, until the Cube reports it
        SafetyTries = 0
        SafetyUseSetMode = false   % true once the Cube has said it doesn't know command 5300
        WantedParams = strings(1, 0)   % parameters asked for, re-asked until they arrive
        ParamTries = 0      % how many times the missing ones have been re-asked
        LastReopen = []     % when the USB port was last opened (tic), for reopenSerial
    end

    properties (Constant, Access = private)
        MaxParamTries = 10  % give up re-asking after this many seconds
        MaxSafetyTries = 3  % re-send a safety switch request this many times
        % MAVLink numbers that MATLAB's message dictionary is too old to know:
        SafetyCommand = 5300     % MAV_CMD_DO_SET_SAFETY_SWITCH_STATE (ArduPlane 4.6.0 and later)
        ScriptCommand = 31010    % MAV_CMD_USER_1, which lua/cubegui.lua listens for
        ScriptingCommand = 42701 % MAV_CMD_SCRIPTING; param1 3 stops and restarts every script
        RebootCommand = 246      % MAV_CMD_PREFLIGHT_REBOOT_SHUTDOWN; param1 1 reboots the autopilot
        SafetyModeFlag = 128     % MAV_MODE_FLAG_DECODE_POSITION_SAFETY, for the older way
        Unsupported = 3          % MAV_RESULT_UNSUPPORTED
    end

    methods
        function obj = CubeSource(telemetry, localPort, cubeAddress, cubePort, rateHz, serialPort)
            obj.Telemetry = telemetry;
            if nargin >= 6
                obj.SerialPort = string(serialPort);
            end
            obj.LocalPort = localPort;
            obj.CubeAddress = string(cubeAddress);
            obj.CubePort = cubePort;
            obj.RateHz = rateHz;
            obj.Logs = LogDownload();
            obj.Upload = FtpUpload();
        end

        function connect(obj)
            if obj.IsConnected
                return
            end
            if ~exist("mavlinkio", "file")
                error("CubeGUI:noToolbox", ['Talking to a Cube needs MATLAB''s UAV Toolbox, ' ...
                    'which isn''t installed. Install it from Add-Ons, or choose Simulated.'])
            end

            obj.Dialect = mavlinkdialect("common.xml");
            obj.Io = mavlinkio(obj.Dialect, SystemID=255, ComponentID=190);
            if obj.SerialPort ~= ""
                obj.connectSerial();
            else
                obj.connectUdp();
            end
            obj.subscribe();
            obj.buildMessages();

            % Once a second: heartbeat, and ask again for any message that
            % isn't arriving fast enough (this also covers a Cube that reboots).
            obj.Timer = timer(ExecutionMode="fixedRate", Period=1, BusyMode="drop", ...
                Name="CubeGUI Cube heartbeat", TimerFcn=@(~, ~) obj.everySecond());
            obj.IsConnected = true;
            start(obj.Timer)
        end

        function disconnect(obj)
            % Tell the Cube to stop sending a log, so it goes back to logging.
            if ~isempty(obj.Io) && ismember(obj.Logs.State, ["downloading", "listing"])
                obj.sendLogRequests(obj.Logs.cancel());
            end
            if ~isempty(obj.Timer) && isvalid(obj.Timer)
                stop(obj.Timer)
                delete(obj.Timer)
            end
            obj.Timer = [];
            obj.Subscriptions = {};
            obj.WantedParams = strings(1, 0);
            if ~isempty(obj.Io)
                disconnect(obj.Io)
                obj.Io = [];
            end
            obj.IsConnected = false;
        end

        function text = describe(obj)
            if obj.SerialPort ~= ""
                text = sprintf("Cube on USB (%s)", obj.SerialPort);
            else
                text = sprintf("Cube at %s", obj.CubeAddress);
            end
        end

        function requestParams(obj, names)
            % Ask for each parameter by name. Any that don't arrive are asked
            % for again once a second (UDP messages can get lost on Wi-Fi).
            obj.WantedParams = unique([obj.WantedParams, string(names)]);
            obj.ParamTries = 0;
            obj.askForMissingParams();
        end

        function setSafety(obj, on)
            % Turn the safety switch on or off. Re-sent once a second until
            % SYS_STATUS shows the change (or MaxSafetyTries runs out).
            obj.SafetyWanted = on;
            obj.SafetyTries = 0;
            obj.sendSafety();
        end

        function sendScriptCommand(obj, mode, targetDeg, sas)
            % COMMAND_LONG with MAV_CMD_USER_1, which lua/cubegui.lua
            % handles itself: param1 mode, param2 pitch target, param3 SAS.
            % MATLAB's message list is older than some commands, so start
            % from any COMMAND_LONG and change its number (see sendSafety).
            msg = obj.newCommand("MAV_CMD_DO_SET_SERVO");
            msg.Payload.command(:) = obj.ScriptCommand;
            msg.Payload.param1(:) = mode;
            msg.Payload.param2(:) = targetDeg;
            msg.Payload.param3(:) = double(sas);
            obj.send(msg)
        end

        function sendText(obj, text)
            % STATUSTEXT. ArduPilot writes it into the Cube's own log, as a
            % MSG entry (GCS_Common.cpp, handle_statustext). Up to 50 characters.
            text = char(text);
            text = text(1:min(end, 50));
            msg = createmsg(obj.Dialect, "STATUSTEXT");
            msg.Payload.severity(:) = 6;   % MAV_SEVERITY_INFO
            msg.Payload.text(1:numel(text)) = text;
            obj.send(msg)
        end

        function sendLogRequests(obj, requests)
            % Send what obj.Logs asked for: LOG_REQUEST_LIST, _DATA or _END.
            for r = requests
                switch r.kind
                    case "list"
                        msg = createmsg(obj.Dialect, "LOG_REQUEST_LIST");
                        msg.Payload.start(:) = 0;
                        msg.Payload.end(:) = 65535;   % every log
                    case "data"
                        msg = createmsg(obj.Dialect, "LOG_REQUEST_DATA");
                        msg.Payload.id(:) = r.id;
                        msg.Payload.ofs(:) = r.ofs;
                        msg.Payload.count(:) = r.count;
                    case "end"
                        msg = createmsg(obj.Dialect, "LOG_REQUEST_END");
                end
                msg.Payload.target_system(:) = 1;
                msg.Payload.target_component(:) = 1;
                obj.send(msg)
            end
        end

        function sendFtp(obj, payloads)
            % Send what obj.Upload asked for, one FILE_TRANSFER_PROTOCOL each.
            for k = 1:numel(payloads)
                msg = createmsg(obj.Dialect, "FILE_TRANSFER_PROTOCOL");
                msg.Payload.target_network(:) = 0;
                msg.Payload.target_system(:) = 1;
                msg.Payload.target_component(:) = 1;
                msg.Payload.payload(:) = payloads{k};
                obj.send(msg)
            end
        end

        function restartScripts(obj)
            % Stop and restart every Lua script, so a new copy of one runs
            % without rebooting the Cube.
            msg = obj.newCommand("MAV_CMD_DO_SET_SERVO");   % any command, then change its number
            msg.Payload.command(:) = obj.ScriptingCommand;
            msg.Payload.param1(:) = 3;   % SCRIPTING_CMD_STOP_AND_RESTART
            obj.send(msg)
        end

        function reboot(obj, toBootloader)
            % MAV_CMD_PREFLIGHT_REBOOT_SHUTDOWN with param1 = 1. ArduPilot
            % refuses it while armed (never, with CubeGUI), saves any
            % parameter writes still pending, forces the safety switch on,
            % and restarts (GCS_Common.cpp, handle_preflight_reboot;
            % AP_Vehicle.cpp, reboot). reboot(true) sends param1 = 3
            % instead: restart and stay in the bootloader, ready for new
            % firmware (FirmwareUpload).
            if nargin < 2
                toBootloader = false;
            end
            msg = obj.newCommand("MAV_CMD_DO_SET_SERVO");   % any command, then change its number
            msg.Payload.command(:) = obj.RebootCommand;
            msg.Payload.param1(:) = 1 + 2 * toBootloader;
            obj.send(msg)
        end

        function setParam(obj, name, value)
            % PARAM_SET. The Cube replies with PARAM_VALUE showing the new
            % value, which is how we know it was written.
            msg = createmsg(obj.Dialect, "PARAM_SET");
            msg.Payload.target_system(:) = 1;
            msg.Payload.target_component(:) = 1;
            msg.Payload.param_id(1:strlength(name)) = char(name);
            msg.Payload.param_value(:) = value;
            % ArduPilot sends and takes every parameter as a float.
            msg.Payload.param_type(:) = enum2num(obj.Dialect, "MAV_PARAM_TYPE", "MAV_PARAM_TYPE_REAL32");
            obj.send(msg)
        end
    end

    methods (Access = protected)
        function sendServo(obj, output, pwm)
            cmd = obj.ServoCommand;
            cmd.Payload.param1(:) = output;   % output number, counting from 1
            cmd.Payload.param2(:) = pwm;      % pulse width in us
            obj.send(cmd)
        end
    end

    methods (Access = private)
        function connectUdp(obj)
            % Listen on the laptop's UDP port, where the Kahuna sends the Cube's messages.
            try
                connect(obj.Io, "UDP", LocalPort=obj.LocalPort);
            catch err
                obj.Io = [];
                if CubeSource.isPortInUse(err)
                    error("CubeGUI:portInUse", ['UDP port %d is already in use. Is Mission ' ...
                        'Planner open? Close it, or use its MAVLink forwarding to send the ' ...
                        'data to another port.'], obj.LocalPort)
                end
                error("CubeGUI:connect", "Couldn't open UDP port %d: %s", obj.LocalPort, ...
                    CubeSource.shortMessage(err))
            end
        end

        function connectSerial(obj)
            % Open the USB cable's serial port. UAV Toolbox does MAVLink over
            % a serial port from R2026b (mavlinkio's "Serial" connection).
            if isMATLABReleaseOlderThan("R2026b")
                obj.Io = [];
                error("CubeGUI:serialNeedsR2026b", ['Connecting over USB needs MATLAB R2026b ' ...
                    'or later (this is %s). Use the Wi-Fi instead.'], "R" + version("-release"))
            end
            try
                connect(obj.Io, "Serial", SerialPort=obj.SerialPort, BaudRate=obj.SerialBaud);
                obj.LastReopen = tic;
            catch err
                obj.Io = [];
                error("CubeGUI:connect", ['Couldn''t open %s: %s Is the Cube plugged in, and ' ...
                    'is Mission Planner (or another program) using the port? Close it and try again.'], ...
                    obj.SerialPort, CubeSource.shortMessage(err))
            end
        end

        function subscribe(obj)
            % Subscribe to the Cube's autopilot only (system 1, component 1),
            % so the Kahuna's own messages are ignored. Each callback just
            % stores the data in the Telemetry object. They hold on to the
            % Telemetry object, not this one, so nothing here is kept alive
            % by its own callbacks, and deleting the source really frees it.
            %
            % BufferSize matters. With the default of 1, a subscription keeps
            % only the newest message, so anything that arrives while MATLAB
            % is busy (opening a window, say) is thrown away before the
            % callback sees it. Testing showed a 2 s gap in the log that way.
            % 200 messages covers about 10 s of busy at 20 Hz.
            tel = obj.Telemetry;
            logs = obj.Logs;   % the log callbacks hold this, not the source, for the same reason
            upload = obj.Upload;
            cube = mavlinkclient(obj.Io, 1, 1);
            n = obj.SubscriptionBuffer;
            obj.Subscriptions = {
                mavlinksub(obj.Io, cube, "HEARTBEAT", BufferSize=n, ...
                    NewMessageFcn=@(~, msg) tel.addHeartbeat(double(msg.Payload.type)))
                mavlinksub(obj.Io, cube, "ATTITUDE", BufferSize=n, ...
                    NewMessageFcn=@(~, msg) tel.addPitch(double(msg.Payload.time_boot_ms) / 1000, ...
                        rad2deg(double(msg.Payload.pitch)), rad2deg(double(msg.Payload.pitchspeed))))
                mavlinksub(obj.Io, cube, "SERVO_OUTPUT_RAW", BufferSize=n, ...
                    NewMessageFcn=@(~, msg) tel.addOutputsUsec( ...
                        double(msg.Payload.time_usec), CubeSource.outputsFrom(msg.Payload)))
                mavlinksub(obj.Io, cube, "COMMAND_ACK", BufferSize=n, ...
                    NewMessageFcn=@(~, msg) tel.addAck( ...
                        double(msg.Payload.command), double(msg.Payload.result)))
                mavlinksub(obj.Io, cube, "PARAM_VALUE", BufferSize=n, ...
                    NewMessageFcn=@(~, msg) tel.addParam( ...
                        CubeSource.text(msg.Payload.param_id), double(msg.Payload.param_value)))
                mavlinksub(obj.Io, cube, "AUTOPILOT_VERSION", BufferSize=n, ...
                    NewMessageFcn=@(~, msg) tel.setVersion(CubeSource.versionFrom(msg.Payload)))
                mavlinksub(obj.Io, cube, "SYS_STATUS", BufferSize=n, ...
                    NewMessageFcn=@(~, msg) tel.addSysStatus( ...
                        double(msg.Payload.onboard_control_sensors_enabled)))
                mavlinksub(obj.Io, cube, "RC_CHANNELS", BufferSize=n, ...
                    NewMessageFcn=@(~, msg) tel.addRc( ...
                        double(msg.Payload.time_boot_ms) / 1000, CubeSource.rcFrom(msg.Payload)))
                mavlinksub(obj.Io, cube, "NAMED_VALUE_FLOAT", BufferSize=n, ...
                    NewMessageFcn=@(~, msg) tel.addNamedValue(CubeSource.text(msg.Payload.name), ...
                        double(msg.Payload.value), double(msg.Payload.time_boot_ms) / 1000))
                mavlinksub(obj.Io, cube, "LOG_ENTRY", BufferSize=n, ...
                    NewMessageFcn=@(~, msg) logs.addEntry(double(msg.Payload.id), ...
                        double(msg.Payload.num_logs), double(msg.Payload.time_utc), ...
                        double(msg.Payload.size)))
                mavlinksub(obj.Io, cube, "LOG_DATA", BufferSize=obj.LogDataBuffer, ...
                    NewMessageFcn=@(~, msg) logs.addData(double(msg.Payload.id), ...
                        double(msg.Payload.ofs), double(msg.Payload.count), msg.Payload.data))
                mavlinksub(obj.Io, cube, "FILE_TRANSFER_PROTOCOL", BufferSize=n, ...
                    NewMessageFcn=@(~, msg) upload.addReply(msg.Payload.payload))
                };
        end

        function reopenSerial(obj)
            % A Cube that reboots drops off USB for a few seconds, and comes
            % back as a new device on the same port. The old connection hears
            % nothing from the new one (Robin had to click Disconnect and
            % Connect), so everySecond opens it again once it's back. Over the
            % Wi-Fi this isn't needed: the Kahuna stays up while the Cube reboots.
            obj.Subscriptions = {};
            try
                disconnect(obj.Io)
            catch
                % the old port has gone, so there may be nothing to close
            end
            obj.Io = mavlinkio(obj.Dialect, SystemID=255, ComponentID=190);
            connect(obj.Io, "Serial", SerialPort=obj.SerialPort, BaudRate=obj.SerialBaud);
            obj.subscribe();
        end

        function buildMessages(obj)
            d = obj.Dialect;

            hb = createmsg(d, "HEARTBEAT");
            hb.Payload.type(:) = enum2num(d, "MAV_TYPE", "MAV_TYPE_GCS");
            hb.Payload.autopilot(:) = enum2num(d, "MAV_AUTOPILOT", "MAV_AUTOPILOT_INVALID");
            hb.Payload.system_status(:) = enum2num(d, "MAV_STATE", "MAV_STATE_ACTIVE");
            hb.Payload.mavlink_version(:) = 3;
            obj.Heartbeat = hb;

            % One rate request per message, each with a check that says
            % whether that message is arriving too slowly (so ask again).
            tel = obj.Telemetry;
            wanted = obj.RateHz;
            names = ["ATTITUDE", "SERVO_OUTPUT_RAW", "SYS_STATUS", "RC_CHANNELS"];
            rates = [wanted, wanted, 2, 5];   % SYS_STATUS only carries the safety state
            tooSlow = {@() CubeSource.measuredRate(tel.Pitch) < 0.8 * wanted, ...
                       @() CubeSource.measuredRate(tel.Outputs) < 0.8 * wanted, ...
                       @() tel.secondsSinceSafety() > 2, ...
                       @() CubeSource.measuredRate(tel.Rc) < 2};
            obj.RateRequests = struct("command", {}, "tooSlow", {});
            for k = 1:numel(names)
                cmd = obj.newCommand("MAV_CMD_SET_MESSAGE_INTERVAL");
                cmd.Payload.param1(:) = msginfo(d, names(k)).MessageID;
                cmd.Payload.param2(:) = 1e6 / rates(k);   % interval in us
                obj.RateRequests(k) = struct("command", cmd, "tooSlow", tooSlow(k));
            end

            obj.ServoCommand = obj.newCommand("MAV_CMD_DO_SET_SERVO");

            obj.VersionRequest = obj.newCommand("MAV_CMD_REQUEST_MESSAGE");
            obj.VersionRequest.Payload.param1(:) = msginfo(d, "AUTOPILOT_VERSION").MessageID;
        end

        function sendSafety(obj)
            on = obj.SafetyWanted;
            if obj.SafetyUseSetMode
                % The older way, which Mission Planner's "Toggle Saftey Switch"
                % uses: SET_MODE with only the safety flag set. Mode 1 turns
                % safety on and 0 turns it off; nothing else changes.
                msg = createmsg(obj.Dialect, "SET_MODE");
                msg.Payload.target_system(:) = 1;
                msg.Payload.base_mode(:) = obj.SafetyModeFlag;
                msg.Payload.custom_mode(:) = double(on);
            else
                % COMMAND_LONG with command 5300. param1: 0 = safe (on), 1 = off.
                msg = obj.newCommand("MAV_CMD_DO_SET_SERVO");   % any command, then change its number
                msg.Payload.command(:) = obj.SafetyCommand;
                msg.Payload.param1(:) = double(~on);
            end
            obj.send(msg)
        end

        function checkSafety(obj)
            % Called once a second while a safety change is waiting.
            if isnan(obj.SafetyWanted)
                return
            end
            tel = obj.Telemetry;
            if isequal(tel.SafetyOn, obj.SafetyWanted)
                obj.SafetyWanted = NaN;   % done
                return
            end
            if tel.LastAck.command == obj.SafetyCommand && tel.LastAck.result == obj.Unsupported ...
                    && ~obj.SafetyUseSetMode
                % Older firmware: try the other way, and give it its own tries.
                obj.SafetyUseSetMode = true;
                obj.SafetyTries = 0;
            end
            if obj.SafetyTries < obj.MaxSafetyTries
                obj.SafetyTries = obj.SafetyTries + 1;
                obj.sendSafety();
            else
                obj.SafetyWanted = NaN;   % give up; the window says it didn't work
            end
        end

        function askForMissingParams(obj)
            tel = obj.Telemetry;
            for name = obj.WantedParams
                if ~isKey(tel.Params, name)
                    msg = createmsg(obj.Dialect, "PARAM_REQUEST_READ");
                    msg.Payload.target_system(:) = 1;
                    msg.Payload.target_component(:) = 1;
                    msg.Payload.param_id(1:strlength(name)) = char(name);
                    msg.Payload.param_index(:) = -1;   % -1: find it by name
                    obj.send(msg)
                end
            end
        end

        function cmd = newCommand(obj, name)
            cmd = createcmd(obj.Dialect, "long", name);
            cmd.Payload.target_system(:) = 1;
            cmd.Payload.target_component(:) = 1;
        end

        function send(obj, msg)
            if obj.SerialPort ~= ""
                sendserialmsg(obj.Io, msg, obj.SerialPort);
            else
                sendudpmsg(obj.Io, msg, obj.CubeAddress, obj.CubePort);
            end
        end

        function everySecond(obj)
            % A timer stops for good if its function errors, so catch everything.
            try
                if obj.SerialPort ~= "" && obj.Telemetry.secondsSinceHeartbeat() > 3
                    % Silent over USB: the Cube may be rebooting. Wait for its
                    % port to come back, then open it again (every 3 s at most).
                    if ~ismember(obj.SerialPort, serialportlist("available"))
                        return
                    end
                    if toc(obj.LastReopen) > 3
                        obj.LastReopen = tic;
                        obj.reopenSerial();
                    end
                end
                obj.send(obj.Heartbeat)
                for k = 1:numel(obj.RateRequests)
                    if obj.RateRequests(k).tooSlow()
                        obj.send(obj.RateRequests(k).command)
                    end
                end
                obj.checkSafety();
                % Only ask for the version and parameters once the Cube is
                % answering, then keep asking until they arrive.
                if obj.Telemetry.secondsSinceHeartbeat() < 2
                    if isempty(obj.Telemetry.Version)
                        obj.send(obj.VersionRequest)
                    end
                    if obj.ParamTries < obj.MaxParamTries
                        obj.ParamTries = obj.ParamTries + 1;
                        obj.askForMissingParams();
                    end
                end
            catch err
                fprintf(2, "CubeGUI heartbeat timer: %s\n", err.message);
            end
        end
    end

    methods (Static, Hidden)
        function found = findMavlink(ports, seconds)
            % Which of these serial ports ArduPilot is talking MAVLink on:
            % "MAVLink", "not MAVLink" or "in use", one for each port, or ""
            % for all of them if this MATLAB can't tell (before R2026b).
            %
            % It opens every port with UAV Toolbox, the same way connectSerial
            % does, and listens for a few seconds: ArduPilot sends a HEARTBEAT
            % every second, along with its other messages. It sends nothing,
            % so the Cube's second port (SLCAN, a CAN-bus link) and other
            % devices aren't disturbed.
            %
            % Why not MATLAB's serialport? On a Mac with a real Cube (tested
            % 4 Nov 2026), serialport heard nothing until something had been
            % written to the port, but mavlinkio heard a heartbeat within
            % 0.1 s of opening it, every time.
            found = repmat("not MAVLink", size(ports));
            if isMATLABReleaseOlderThan("R2026b") || ~exist("mavlinkio", "file")
                found(:) = "";
                return
            end
            listening = cell(size(ports));
            for k = 1:numel(ports)
                io = mavlinkio("common.xml", SystemID=255, ComponentID=190);
                try
                    connect(io, "Serial", SerialPort=ports(k), BaudRate=CubeSource.SerialBaud);
                    listening{k} = io;
                catch
                    found(k) = "in use";
                    delete(io)
                end
            end
            pause(seconds)
            for k = 1:numel(ports)
                if ~isempty(listening{k})
                    clients = listClients(listening{k});   % includes us, system 255
                    if any(clients.SystemID ~= 255)
                        found(k) = "MAVLink";
                    end
                    disconnect(listening{k})
                    delete(listening{k})
                end
            end
        end

        % Hidden rather than private, because the message callbacks call
        % these after connect() has returned, and the tests check them.
        function s = text(chars)
            % MAVLink text fields are fixed-length and padded with zeros;
            % deblank removes the padding.
            s = string(deblank(char(chars(:)')));
        end

        function info = versionFrom(p)
            % Unpack AUTOPILOT_VERSION. The firmware version is packed into one
            % number: major, minor and patch in its top three bytes, and a
            % release type in the bottom one.
            v = double(p.flight_sw_version);
            major = floor(v / 2^24);
            minor = mod(floor(v / 2^16), 256);
            patch = mod(floor(v / 2^8), 256);
            types = dictionary([0 64 128 192 255], ["dev", "alpha", "beta", "rc", "official"]);
            kind = mod(v, 256);
            if isKey(types, kind)
                kindText = types(kind);
            else
                kindText = "type " + kind;
            end
            info = struct( ...
                "firmware", sprintf("%d.%d.%d (%s)", major, minor, patch, kindText), ...
                "git", CubeSource.text(p.flight_custom_version), ...  % ArduPilot puts its git hash here
                "board", sprintf("0x%08X", double(p.board_version)), ...
                "uid", string(dec2hex(p.uid)));
        end

        function tf = isPortInUse(err)
            % MATLAB's error passes on the operating system's, with its
            % number, e.g. on macOS: "bind: Address already in use
            % [system:48 at ...]". The number for "address in use" is 48 on
            % macOS, 98 on Linux and 10048 on Windows, whose text is "Only
            % one usage of each socket address..." in English. Checking the
            % number as well covers Windows in other languages.
            % GUESS: the Windows wording and number are from Microsoft's
            % documentation (WSAEADDRINUSE); not yet seen from MATLAB.
            tf = contains(err.message, ["Address already in use", ...
                "Only one usage of each socket address", ...
                "system:48 ", "system:98 ", "system:10048 "], IgnoreCase=true);
        end

        function pwm = rcFrom(payload)
            % RC_CHANNELS has fields chan1_raw ... chan18_raw.
            pwm = zeros(1, 18);
            for k = 1:18
                pwm(k) = double(payload.("chan" + k + "_raw"));
            end
        end

        function pwm = outputsFrom(payload)
            % SERVO_OUTPUT_RAW has fields servo1_raw ... servo16_raw.
            pwm = zeros(1, 16);
            for k = 1:16
                pwm(k) = double(payload.("servo" + k + "_raw"));
            end
        end
    end

    methods (Static, Access = private)

        function rate = measuredRate(buffer)
            % Samples per second over the last 2 s of Cube time.
            [t, ~] = buffer.data();
            if numel(t) < 2
                rate = 0;
            else
                rate = sum(t > t(end) - 2) / 2;
            end
        end

        function text = shortMessage(err)
            % MATLAB's network errors end in a long technical part in [ ].
            text = strtrim(extractBefore(string(err.message) + " [", " ["));
        end
    end
end
