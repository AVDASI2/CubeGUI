classdef CubeGuiApp < handle
    %CUBEGUIAPP  The CubeGUI window. Start it with CubeGUI, not directly.
    %
    %   Part of CubeGUI's engine. You don't need to change this: see the
    %   panels folder and docs/recipes.md.
    %
    %   The window is built in code from uifigure, uigridlayout and friends,
    %   so every change shows up as readable text in git.
    %
    %   How it fits together:
    %     data source (Cube or Simulated) --stores--> Telemetry
    %     redraw timer, 10 times a second --> each panel's update --> reads it through cube
    %     a panel's slider or button --> cube.moveServo --> DataSource.setServo (clamped) --> Cube
    %
    %   The window itself owns the connection bar, the safety switch, the
    %   Setup tab and the status line. Everything else on the Run tab is a
    %   panel: a short function file in the panels folder, listed under
    %   "plots" and "controls" in the settings file. A panel that goes wrong
    %   is reported and switched off, and the rest of the window carries on.
    %
    %   Two tabs: Run (plots and controls) and Setup (Cube parameters,
    %   versions and values from Lua scripts). The capability level in the
    %   settings decides what's shown (see levels.m).

    properties (SetAccess = private)
        Config
        Telemetry
        Source = []          % the connected DataSource, or [] when disconnected
        Logger               % the CsvLogger
        Figure
        Cube                 % what the panels are given to talk to the Cube (Cube.m)
        Level                % the capability level the window was opened at
    end

    properties (Constant)
        HeartbeatTimeout = 2     % seconds without a heartbeat before the lamp goes red
        RedrawPeriod = 0.1       % redraw 10 times a second
        DoSetServo = 183         % MAV_CMD_DO_SET_SERVO's number, for spotting its replies
        GainNames = ["CGUI_KP", "CGUI_KI", "CGUI_KD"]   % lua/cubegui.lua's PID gains
        % Parameters that only take effect when the Cube restarts
        RebootParams = ["SCR_ENABLE", "BRD_SAFETY_DEFLT"]
    end

    properties (Access = private)
        % Connection bar and status line
        SourceDropDown
        AddressLabel
        AddressField
        SerialDropDown       % the USB port, in place of the address (Cube (USB))
        CubePortField
        LocalPortField
        UdpControls          % the Cube port and Listen port boxes and labels, hidden over USB
        ConnectButton
        LogLabel
        Lamp
        LampLabel
        StatusLabel

        % Run tab: the panels' update functions, called by the redraw timer
        Panels = struct("name", {}, "update", {}, "holder", {}, "failed", {})

        % Logs panel (Run tab, from level 1)
        LogWanted            % true: keep a CSV log while connected
        LaptopLogButton
        LaptopLogLabel
        CubeLogButton
        CubeLogLabel
        DownloadButton
        CancelButton
        DownloadLabel
        DownloadWaiting = false   % true while the Cube lists its logs, before asking to download

        % Closed-loop gains panel (Run tab, from level 3)
        GainBoxes            % one numeric box per gain, in the order of GainNames
        GainShown            % the Cube's value each box last showed

        % Script install (Setup tab, from level 2)
        InstallButton
        InstallLabel

        % Firmware over USB (Setup tab, from level 1)
        FlashButton
        FlashLabel

        % A reboot waiting for parameter writes to be confirmed first
        RebootAfter = struct("name", {}, "value", {})

        % Safety switch panel (Run tab)
        SafetyLamp
        SafetyLabel
        SafetyButton
        SafetyRequest = []   % struct(wanted, tic) while waiting for the Cube to change

        % Setup tab
        Tabs                 % the tab group, to know which tab is showing
        SetupTab
        Checks               % from setupParameters
        ParamTable
        AddField             % for adding a parameter by name
        Edits                % values typed into "New value", by name (a dictionary)
        Writes = struct("name", {}, "value", {}, "tic", {}, "tries", {})  % waiting for the Cube to confirm
        AskedAt              % laptop time each parameter was asked for, by name
        VersionLabels        % struct of labels: firmware, vehicle, git, board, uid
        LuaTable
        LuaPanel

        RedrawTimer
        RedrawCount = 0
        ConnectTic = []      % when we connected, for the "waiting" message
        AcksSeen = 0         % COMMAND_ACKs already looked at
        RebootsSeen = 0      % Cube reboots already reported
        VersionShown = []
    end

    % ======================================================================
    methods
        function obj = CubeGuiApp(config)
            obj.Config = config;
            obj.Level = config.level;
            obj.LogWanted = config.logging.enabled;
            obj.Telemetry = Telemetry(config.rates.plotSeconds, config.rates.telemetryHz);
            obj.Logger = CsvLogger(obj.Telemetry, config.servos, config.logging.folder, ...
                config.logging.extraSignals);
            obj.Cube = Cube(obj.Telemetry, config.servos, config.level, ...
                config.rates.plotSeconds, @(text, isProblem) obj.setStatus(text, isProblem));
            obj.Checks = setupParameters(config.servos, config.setup.extraParams, config.level);
            obj.Edits = dictionary(string.empty, double.empty);
            obj.AskedAt = dictionary(string.empty, double.empty);
            obj.buildWindow();
            obj.RedrawTimer = timer(ExecutionMode="fixedRate", Period=obj.RedrawPeriod, ...
                BusyMode="drop", Name="CubeGUI redraw", TimerFcn=@(~, ~) obj.redraw());
            start(obj.RedrawTimer)
        end

        function connect(obj, sourceName, serialPort)
            % Connect to the source chosen in the drop-down (or the one named).
            % For Cube (USB), serialPort names the port instead of the drop-down.
            if ~isempty(obj.Source)
                return
            end
            if nargin > 1
                obj.SourceDropDown.Value = sourceName;
            end
            obj.Telemetry.clear();
            obj.AcksSeen = 0;
            obj.RebootsSeen = 0;
            obj.VersionShown = [];
            obj.SafetyRequest = [];
            obj.Writes = obj.Writes([]);
            obj.RebootAfter = obj.RebootAfter([]);
            obj.Edits = dictionary(string.empty, double.empty);

            if obj.SourceDropDown.Value == "Simulated"
                source = SimulatedSource(obj.Telemetry);
                source.ElevatorOutput = obj.elevatorOutput();
            elseif obj.SourceDropDown.Value == "Cube (USB)"
                port = string(obj.SerialDropDown.Value);
                if nargin > 2
                    port = string(serialPort);   % named by the caller (the tests)
                elseif ~ismember(port, usbPorts())
                    obj.setStatus("No USB port found. Plug in the Cube's USB cable, " + ...
                        "then choose Cube (USB) again.", true);
                    return
                end
                source = CubeSource(obj.Telemetry, obj.LocalPortField.Value, ...
                    obj.AddressField.Value, obj.CubePortField.Value, obj.Config.rates.telemetryHz, port);
            else
                source = CubeSource(obj.Telemetry, obj.LocalPortField.Value, ...
                    obj.AddressField.Value, obj.CubePortField.Value, obj.Config.rates.telemetryHz);
            end
            try
                source.connect();
            catch err
                delete(source)
                obj.setStatus(err.message, true);
                uialert(obj.Figure, err.message, "Couldn't connect");
                return
            end
            obj.Source = source;
            obj.ConnectTic = tic;
            obj.setStatus("Connected to " + source.describe() + ".", false);
            obj.updateConnectionControls();
            obj.askFor(obj.parametersToRead());
            % The servos' limits come from the Cube's parameters, so they
            % switch on as those arrive (straight away for Simulated).
            obj.Cube.attach(source);
            if obj.LogWanted && obj.Level >= 1
                obj.startLogging();
            end
        end

        function disconnect(obj)
            if isempty(obj.Source)
                return
            end
            % Forget the source first, then shut it down. Shutting down the
            % network can let the redraw timer run in the middle, and it
            % must not find a half-deleted source.
            source = obj.Source;
            obj.Source = [];
            obj.Cube.detach();
            obj.stopLogging();
            source.disconnect();
            delete(source)
            obj.setStatus("Disconnected.", false);
            obj.updateConnectionControls();
        end

        function startLogging(obj)
            % Start a new log file (only while connected).
            if isempty(obj.Source) || obj.Logger.IsLogging
                return
            end
            try
                obj.Logger.start();
            catch err
                obj.LogWanted = false;
                obj.setStatus("Logging didn't start: " + err.message, true);
            end
        end

        function stopLogging(obj)
            if obj.Logger.IsLogging
                obj.Logger.stop();
                [~, name, ext] = fileparts(obj.Logger.File);
                showText(obj.LogLabel, sprintf("Saved %s%s (%d rows)", name, ext, obj.Logger.RowCount));
            end
        end

        function sent = commandServo(obj, index, value)
            % Send servo number index (in the settings' order) to value, in
            % its own units, straight away. Returns the PWM sent, or NaN.
            % For the tests and the Command Window; panels use cube.moveServo.
            sent = obj.Cube.sendNow(obj.Config.servos(index).name, value);
        end

        function zeroAll(obj)
            % Send every servo its trim PWM.
            obj.Cube.zeroAll();
        end

        function changes = setupChanges(obj)
            % The parameters Apply would write: name, current value and new value.
            % That's everything with a value in the "New value" column: either
            % one you typed, or the value CubeGUI needs if it isn't right yet.
            changes = struct("name", {}, "from", {}, "to", {});
            if isempty(obj.Source)
                return
            end
            for c = obj.Checks
                value = obj.Telemetry.param(c.name);
                target = obj.newValue(c, value);
                if ~c.readOnly && ~isnan(value) && ~isnan(target) && ~sameValue(target, value)
                    changes(end+1) = struct("name", c.name, "from", value, "to", target); %#ok<AGROW>
                end
            end
        end

        function setNewValue(obj, name, value)
            % Put a value in a parameter's "New value" cell (NaN clears it),
            % as if typed. Apply then writes it.
            name = string(name);
            c = obj.Checks([obj.Checks.name] == name);
            if isempty(c)
                error("CubeGUI:param", "%s isn't in the Setup table.", name)
            end
            if c.readOnly
                error("CubeGUI:param", ['CubeGUI won''t change %s, because a wrong value ' ...
                    'could cut it off from the Cube. Change it over USB in Mission Planner.'], name)
            end
            if isnan(value)
                if isKey(obj.Edits, name)
                    obj.Edits(name) = [];
                end
            else
                obj.Edits(name) = value;
            end
            obj.refreshParamTable();
        end

        function applySetup(obj, askFirst)
            % Write every value in the "New value" column, after a confirmation
            % listing exactly what will change. applySetup(false) skips the
            % question; it's there for the automated tests.
            if nargin < 2
                askFirst = true;
            end
            changes = obj.setupChanges();
            if isempty(changes)
                obj.setStatus("Nothing to change: every parameter is already at its new value.", false);
                return
            end
            lines = strings(1, numel(changes));
            for k = 1:numel(changes)
                lines(k) = sprintf("%s:  %s  →  %s", changes(k).name, ...
                    showNumber(changes(k).from), showNumber(changes(k).to));
            end
            if ~askFirst
                obj.writeParams(changes);
                return
            end
            uiconfirm(obj.Figure, ["CubeGUI will write these to the Cube:", "", lines], ...
                "Change Cube parameters?", Options=["Write to Cube", "Cancel"], ...
                DefaultOption=2, CancelOption=2, Icon="warning", ...
                CloseFcn=@(~, event) obj.confirmed(event.SelectedOption, changes));
        end

        function readSetupAgain(obj)
            if isempty(obj.Source)
                obj.setStatus("Connect first to read the Cube's parameters.", true);
                return
            end
            obj.Telemetry.forgetParams([obj.Checks.name]);
            obj.askFor(obj.parametersToRead());
            obj.refreshParamTable();
            obj.setStatus("Reading the Cube's parameters again...", false);
        end

        function addParameter(obj, name)
            % Add a parameter to the Setup table by name, and read it.
            name = upper(strtrim(string(name)));
            if isempty(regexp(name, "^[A-Z][A-Z0-9_]{0,15}$", "once"))
                obj.setStatus(['A parameter name is up to 16 capital letters, digits and ' ...
                    'underscores, like SERVO8_FUNCTION.'], true);
                return
            end
            if ismember(name, [obj.Checks.name])
                obj.setStatus(name + " is already in the table.", false);
                return
            end
            extra = setupParameters(obj.Config.servos(1:0), name);
            obj.Checks(end+1) = extra(end);
            if ~isempty(obj.Source)
                obj.askFor(name);
            end
            obj.refreshParamTable();
            obj.setStatus(name + " added for this session. To keep it, add it to " + ...
                """extraParams"" under ""setup"" in the settings file.", false);
        end

        function setSafety(obj, on, askFirst)
            % Turn the safety switch on (servos held) or off (servos live).
            % Turning it off asks first; setSafety(false, false) doesn't
            % (that's for the automated tests).
            if nargin < 3
                askFirst = true;
            end
            if isempty(obj.Source)
                obj.setStatus("Connect first.", true);
                return
            end
            if ~on && askFirst
                uiconfirm(obj.Figure, ["Turning the safety switch off lets PWM reach the servos.", ...
                    "They may move straight to their last positions, so keep hands clear.", "", ...
                    "CubeGUI still won't arm the Cube."], "Turn the safety switch off?", ...
                    Options=["Turn it off", "Cancel"], DefaultOption=2, CancelOption=2, ...
                    Icon="warning", CloseFcn=@(~, event) obj.safetyConfirmed(event.SelectedOption));
                return
            end
            obj.Source.setSafety(on);
            obj.SafetyRequest = struct("wanted", on, "tic", tic);
            obj.setStatus("Asking the Cube to turn the safety switch " + ...
                string(ifElse(on, "on", "off")) + "...", false);
        end

        function close(obj)
            % Shut everything down in order: timers, connection, window.
            if ~isempty(obj.RedrawTimer) && isvalid(obj.RedrawTimer)
                stop(obj.RedrawTimer)
                delete(obj.RedrawTimer)
            end
            obj.RedrawTimer = [];
            obj.disconnect();   % also stops the logger and closes the log file
            if ~isempty(obj.Figure) && isvalid(obj.Figure)
                delete(obj.Figure)
            end
        end

        function delete(obj)
            obj.close();
        end
    end

    % ======================================================================
    methods (Access = private)
        function out = elevatorOutput(obj)
            % The output the simulation treats as the elevator: the servo
            % called "Elevator", or else the first one.
            names = lower([obj.Config.servos.name]);
            k = find(names == "elevator", 1);
            if isempty(k)
                k = 1;
            end
            out = obj.Config.servos(k).output;
        end

        function names = parametersToRead(obj)
            % The Setup tab's parameters, plus every servo's limits, which
            % CubeGUI needs at every level (even without the Setup tab).
            names = [obj.Checks.name];
            for s = reshape(obj.Config.servos, 1, [])
                names = [names, "SERVO" + s.output + ["_MIN", "_TRIM", "_MAX"]]; %#ok<AGROW>
            end
            names = unique(names, "stable");
        end

        function confirmed(obj, choice, changes)
            if choice ~= "Write to Cube"
                obj.setStatus("Nothing written.", false);
                return
            end
            obj.writeParams(changes);
            % Some parameters only take effect after a restart: offer one.
            later = changes(ismember([changes.name], obj.RebootParams));
            if ~isempty(later)
                names = strjoin([later.name], " and ");
                uiconfirm(obj.Figure, [names + " only takes effect when the Cube restarts.", "", ...
                    "Reboot the Cube now? CubeGUI waits for the Cube to confirm the write first.", ...
                    "Afterwards the safety switch is on again, so the servos are held still until you turn it off."], ...
                    "Reboot the Cube?", Options=["Reboot now", "Later"], DefaultOption=1, CancelOption=2, ...
                    CloseFcn=@(~, event) obj.rebootAfterWrites(event.SelectedOption, later));
            end
        end

        function rebootAfterWrites(obj, choice, changes)
            if choice == "Reboot now"
                obj.RebootAfter = struct("name", {changes.name}, "value", {changes.to});
                obj.setStatus("The Cube will reboot once it has confirmed the change...", false);
            else
                obj.setStatus("Reboot the Cube (Setup tab, or power it off and on) for the change to take effect.", false);
            end
        end

        function writeParams(obj, changes)
            % The message first: the Cube's confirmation can arrive (and be
            % reported) before this function has finished.
            obj.setStatus(sprintf(['Wrote %d parameter(s). Waiting for the Cube to ' ...
                'confirm...'], numel(changes)), false);
            for c = changes
                obj.Writes(end+1) = struct("name", c.name, "value", c.to, "tic", tic, "tries", 1);
                obj.Source.setParam(c.name, c.to);
            end
            obj.refreshParamTable();
        end

        function safetyConfirmed(obj, choice)
            if choice == "Turn it off"
                obj.setSafety(false, false);
            else
                obj.setStatus("Safety switch left on.", false);
            end
        end

        function askFor(obj, names)
            % Ask the Cube for these parameters, noting when, so the table can
            % say "not on this Cube" if they never arrive.
            now = obj.Telemetry.laptopTime();
            for name = string(names)
                obj.AskedAt(name) = now;
            end
            obj.Source.requestParams(names);
        end

        function target = newValue(obj, check, current)
            % The "New value" for a parameter: what you typed, or else what
            % CubeGUI needs if the current value isn't right. NaN if neither.
            target = NaN;
            if isKey(obj.Edits, check.name)
                target = obj.Edits(check.name);
            elseif ~isnan(check.wanted) && ~isnan(current) && ~check.isOk(current)
                target = check.wanted;
            end
        end

        % ---- Building the window ------------------------------------------------

        function buildWindow(obj)
            allLevels = levels();
            this = allLevels([allLevels.number] == obj.Level);
            windowName = sprintf("CubeGUI, level %d of %d: %s", obj.Level, max([allLevels.number]), this.name);
            if ~this.released
                windowName = windowName + " (preview: not released yet)";
            end
            fig = uifigure(Name=windowName, Position=windowPosition(1180, 780), ...
                CloseRequestFcn=@(~, ~) obj.close());
            obj.Figure = fig;

            % Connection bar on top, tabs in the middle, status line at the bottom.
            main = uigridlayout(fig, [3 1], RowHeight={40, "1x", 24});
            obj.buildConnectionBar(main);

            tabs = uitabgroup(main, SelectionChangedFcn=@(~, ~) obj.tabChanged());
            tabs.Layout.Row = 2;
            obj.Tabs = tabs;
            obj.buildRunTab(uitab(tabs, Title="Run"));
            obj.SetupTab = uitab(tabs, Title="Setup");
            obj.buildSetupTab(obj.SetupTab);
            if obj.Level < 1
                % No Setup tab at level 0. Unparenting it hides it but keeps
                % it working, so nothing else needs to know.
                obj.SetupTab.Parent = [];
            end

            % Its own grid, so the log note takes the width it needs ("fit")
            % and the status message has the rest.
            bottom = uigridlayout(main, [1 2], Padding=[0 0 0 0], ColumnWidth={"1x", "fit"});
            bottom.Layout.Row = 3;
            obj.StatusLabel = uilabel(bottom, Text="Choose a source and click Connect.");
            obj.LogLabel = uilabel(bottom, Text="Not logging", HorizontalAlignment="right");
            if ~this.released
                obj.setStatus(sprintf("Level %d is a preview: tested on ArduPilot's simulator, " + ...
                    "not yet on the kits, and not supported until it's released. See the README.", ...
                    obj.Level), true);
            end

            obj.updateConnectionControls();
        end

        function buildConnectionBar(obj, main)
            bar = uigridlayout(main, [1 11], Padding=[0 0 0 0], ...
                ColumnWidth={50, 100, 90, 120, 70, 70, 80, 70, 100, "1x", "fit"});
            bar.Layout.Row = 1;
            c = obj.Config.connection;

            uilabel(bar, Text="Source", HorizontalAlignment="right");
            sources = ["Simulated", "Cube (Wi-Fi)", "Cube (USB)"];
            if obj.Level < 1
                sources = "Simulated";   % the real Cube comes at level 1
            elseif isMATLABReleaseOlderThan("R2026b")
                sources = ["Simulated", "Cube (Wi-Fi)"];   % UAV Toolbox does MAVLink over USB from R2026b
            end
            obj.SourceDropDown = uidropdown(bar, Items=sources, Value="Simulated", ...
                ValueChangedFcn=@(~, ~) obj.guard(@() obj.sourceChanged()));
            obj.AddressLabel = uilabel(bar, Text="Cube address", HorizontalAlignment="right");
            obj.AddressField = uieditfield(bar, "text", Value=c.cubeAddress);
            % The USB port takes the address's place when the source is Cube (USB).
            obj.SerialDropDown = uidropdown(bar, Items="(none found)", Visible="off");
            obj.SerialDropDown.Layout.Column = obj.AddressField.Layout.Column;   % before the next box is placed
            cubePortLabel = uilabel(bar, Text="Cube port", HorizontalAlignment="right");
            obj.CubePortField = uieditfield(bar, "numeric", Value=c.cubePort, ...
                Limits=[1 65535], RoundFractionalValues="on", ValueDisplayFormat="%d");
            localPortLabel = uilabel(bar, Text="Listen port", HorizontalAlignment="right");
            obj.LocalPortField = uieditfield(bar, "numeric", Value=c.localPort, ...
                Limits=[1 65535], RoundFractionalValues="on", ValueDisplayFormat="%d");
            obj.UdpControls = [cubePortLabel, obj.CubePortField, localPortLabel, obj.LocalPortField];
            % Over USB the UDP ports don't apply, so the port's drop-down
            % takes their space too: a Mac's port names are long
            % ("/dev/cu.usbmodem21301 (MAVLink)").
            obj.SerialDropDown.Layout.Column = [obj.AddressField.Layout.Column, ...
                obj.LocalPortField.Layout.Column];
            obj.ConnectButton = uibutton(bar, Text="Connect", ...
                ButtonPushedFcn=@(~, ~) obj.guard(@() obj.connectPressed()));
            lampBox = uigridlayout(bar, [1 2], Padding=[0 0 0 0], ColumnWidth={24, "1x"});
            obj.Lamp = uilamp(lampBox, Color=[0.6 0.6 0.6]);
            obj.LampLabel = uilabel(lampBox, Text="Not connected");

            if obj.Config.demo
                % Demo mode: step through the levels live, e.g. at a launch.
                allLevels = levels();
                items = compose("Level %d: %s", [allLevels.number]', [allLevels.name]')';
                items(~[allLevels.released]) = items(~[allLevels.released]) + " (preview)";
                uidropdown(bar, Items=items, ItemsData=[allLevels.number], Value=obj.Level, ...
                    ValueChangedFcn=@(src, ~) obj.guard(@() obj.changeLevel(src.Value)));
            end
        end

        function changeLevel(obj, level)
            % Demo mode: close this window and open it again at another level.
            config = obj.Config;
            config.level = level;
            obj.close();
            CubeGuiApp(config);
        end

        function buildRunTab(obj, tab)
            % Plots on the left, controls on the right. Both are lists of
            % panels from the settings file; the safety switch, which is
            % part of the engine, sits at the top of the controls.
            g = uigridlayout(tab, [1 2], ColumnWidth={"1x", 320});
            plots = obj.panelsAtThisLevel(obj.Config.plots);
            controls = obj.panelsAtThisLevel(obj.Config.controls);

            left = uigridlayout(g, [max(numel(plots), 1), 1], Padding=[0 0 0 0], RowSpacing=2);
            heights = repmat({"1x"}, 1, max(numel(plots), 1));
            for k = 1:numel(plots)
                options = plots(k).options;
                options.isLast = (k == numel(plots));   % the bottom plot labels the time axis
                heights{k} = obj.addPanel(left, plots(k).panel, options, "1x");
            end
            left.RowHeight = heights;

            % It scrolls if its panels don't fit the window (a small laptop screen, say).
            right = uigridlayout(g, [numel(controls) + 3, 1], Padding=[0 0 0 0], Scrollable="on");
            obj.buildSafetyPanel(right);
            heights = {64};
            if obj.Level >= 1
                obj.buildLogsPanel(right);
                heights{end+1} = 150;
            end
            if obj.Level >= 3
                obj.buildGainsPanel(right);
                heights{end+1} = 80;
            end
            for k = 1:numel(controls)
                heights{end+1} = obj.addPanel(right, controls(k).panel, controls(k).options, 150); %#ok<AGROW>
            end
            heights{end+1} = "1x";
            right.RowHeight = heights;
        end

        function entries = panelsAtThisLevel(obj, entries)
            entries = entries([entries.level] <= obj.Level);
        end

        function height = addPanel(obj, grid, name, options, height)
            % Make one panel by calling its function: panel = name(parent, cube, options).
            % If it goes wrong, show what went wrong in its place, and carry on.
            holder = uigridlayout(grid, [1 1], Padding=[0 0 0 0]);
            try
                if exist(name, "file") ~= 2
                    error("CubeGUI:panel", "Can't find %s.m in the panels folder. " + ...
                        "Check its name in the settings file.", name)
                end
                panel = feval(name, holder, obj.Cube, options);
                if isstruct(panel) && isfield(panel, "height")
                    height = panel.height;
                end
                if isstruct(panel) && isfield(panel, "update")
                    obj.Panels(end+1) = struct("name", string(name), "update", panel.update, ...
                        "holder", holder, "failed", false);
                end
            catch err
                showPanelProblem(holder, sprintf("%s.m didn't open: %s%s", name, err.message, ...
                    panelLine(err, name)));
            end
        end

        function buildSafetyPanel(obj, parent)
            % No title: the label says "Safety switch ON" or "OFF" itself, so
            % the state can't be read as anything else.
            sp = uipanel(parent);
            sg = uigridlayout(sp, [1 3], ColumnWidth={24, "1x", 90}, Padding=[8 6 8 6]);
            obj.SafetyLamp = uilamp(sg, Color=[0.6 0.6 0.6]);
            obj.SafetyLabel = uilabel(sg, Text="Safety switch: not connected", FontWeight="bold", ...
                WordWrap="on");
            obj.SafetyButton = uibutton(sg, Text="Turn off", Enable="off", ...
                ButtonPushedFcn=@(~, ~) obj.guard(@() obj.safetyPressed()));
        end

        function buildLogsPanel(obj, parent)
            % Start and stop CubeGUI's CSV log and the Cube's own log, and
            % download the Cube's log. Part of the engine, because it
            % writes a Cube parameter (LOG_DISARMED), which always asks first.
            lp = uipanel(parent, Title="Logs");
            lg = uigridlayout(lp, [4 3], ColumnWidth={70, 64, "1x"}, RowHeight={24, 24, 24, 36}, ...
                RowSpacing=3, Padding=[8 4 8 4]);
            uilabel(lg, Text="Laptop");
            obj.LaptopLogButton = uibutton(lg, Text="Start", Enable="off", ...
                ButtonPushedFcn=@(~, ~) obj.guard(@() obj.laptopLogPressed()));
            obj.LaptopLogLabel = uilabel(lg, Text="CSV: connect first");
            uilabel(lg, Text="Cube");
            obj.CubeLogButton = uibutton(lg, Text="Start", Enable="off", ...
                ButtonPushedFcn=@(~, ~) obj.guard(@() obj.cubeLogPressed()));
            obj.CubeLogLabel = uilabel(lg, Text=".BIN: connect first");
            obj.DownloadButton = uibutton(lg, Text="Download Cube log...", Enable="off", ...
                ButtonPushedFcn=@(~, ~) obj.guard(@() obj.downloadPressed()));
            obj.DownloadButton.Layout.Column = [1 3];
            obj.DownloadLabel = uilabel(lg, Text="", WordWrap="on");
            obj.DownloadLabel.Layout.Column = [1 2];
            obj.CancelButton = uibutton(lg, Text="Cancel", Visible="off", ...
                ButtonPushedFcn=@(~, ~) obj.guard(@() obj.cancelDownloadPressed()));
        end

        function buildGainsPanel(obj, parent)
            % The closed loop's PID gains, which are lua/cubegui.lua's
            % parameters on the Cube. Apply asks first, like the Setup tab.
            gp = uipanel(parent, Title="Closed-loop gains (on the Cube)");
            gg = uigridlayout(gp, [2 4], ColumnWidth={"1x", "1x", "1x", 64}, RowHeight={18, 26}, ...
                RowSpacing=2, Padding=[8 4 8 4]);
            % Units: µs of elevator per degree of error, per degree-second,
            % and per degree/second of pitch rate.
            for label = ["Kp (µs/°)", "Ki (µs/°·s)", "Kd (µs·s/°)"]
                uilabel(gg, Text=label, FontSize=11);
            end
            uilabel(gg, Text="");
            obj.GainBoxes = gobjects(1, numel(obj.GainNames));
            for k = 1:numel(obj.GainNames)
                obj.GainBoxes(k) = uieditfield(gg, "numeric", Limits=[0 Inf], Enable="off");
            end
            uibutton(gg, Text="Apply...", ButtonPushedFcn=@(~, ~) obj.guard(@() obj.applyGains()));
            obj.GainShown = NaN(1, numel(obj.GainNames));
        end

        function buildSetupTab(obj, tab)
            g = uigridlayout(tab, [1 2], ColumnWidth={"1x", 340});

            % ---- Parameters ---------------------------------------------------
            left = uigridlayout(g, [3 1], RowHeight={"1x", 34, 44}, Padding=[0 0 0 0]);
            obj.ParamTable = uitable(left, ColumnName=["Group", "Parameter", "On the Cube", ...
                "New value", "Status", "Notes"], ColumnWidth={150, 140, 100, 90, 110, "auto"}, ...
                RowName={}, ColumnEditable=[false false false true false false], ...
                Data=obj.paramRows(), ...
                CellEditCallback=@(~, event) obj.guard(@() obj.cellEdited(event)));
            buttons = uigridlayout(left, [1 7], Padding=[0 0 0 0], ...
                ColumnWidth={110, 140, 120, "1x", 90, 150, 60});
            uibutton(buttons, Text="Read again", ...
                ButtonPushedFcn=@(~, ~) obj.guard(@() obj.readSetupAgain()));
            uibutton(buttons, Text="Apply changes...", ...
                ButtonPushedFcn=@(~, ~) obj.guard(@() obj.applySetup()));
            uibutton(buttons, Text="Reboot Cube...", ...
                ButtonPushedFcn=@(~, ~) obj.guard(@() obj.rebootPressed()));
            uilabel(buttons, Text="");
            uilabel(buttons, Text="Add parameter", HorizontalAlignment="right");
            obj.AddField = uieditfield(buttons, "text", Placeholder="e.g. SERVO8_FUNCTION", ...
                ValueChangedFcn=@(src, ~) obj.guard(@() obj.addPressed()));
            uibutton(buttons, Text="Add", ButtonPushedFcn=@(~, ~) obj.guard(@() obj.addPressed()));
            uilabel(left, WordWrap="on", Text=['Type a value in "New value" to change a ' ...
                'parameter, then click Apply. CubeGUI fills in the values it needs itself. ' ...
                'Apply asks first and lists every change; the table shows when the Cube has ' ...
                'confirmed each one.']);

            % ---- Versions, Lua values, safety switch ------------------------------
            scriptHeight = 0;
            if obj.Level >= 2
                scriptHeight = 100;
            end
            firmwareHeight = 0;
            if obj.Level >= 1
                firmwareHeight = 100;
            end
            % Fixed heights, with a scroll bar when the window is too short,
            % rather than squashing a box until its text is cut off.
            right = uigridlayout(g, [6 1], RowHeight={160, 140, scriptHeight, firmwareHeight, 110, "1x"}, ...
                Padding=[0 0 0 0], Scrollable="on");

            vp = uipanel(right, Title="Autopilot");
            vg = uigridlayout(vp, [5 2], ColumnWidth={80, "1x"}, RowHeight=repmat({20}, 1, 5), ...
                RowSpacing=4);
            labels = struct();
            captions = dictionary(["vehicle", "firmware", "git", "board", "uid"], ...
                ["Vehicle", "Firmware", "Git hash", "Board", "Unique ID"]);
            for f = keys(captions)'
                uilabel(vg, Text=captions(f));
                labels.(f) = uilabel(vg, Text="-");
            end
            obj.VersionLabels = labels;

            lp = uipanel(right, Title="Values from Lua scripts", Visible=obj.Level >= 1);
            obj.LuaPanel = lp;
            lg = uigridlayout(lp, [1 1], Padding=[4 4 4 4]);
            obj.LuaTable = uitable(lg, ColumnName=["Name", "Value"], RowName={}, ...
                Data=table(strings(0, 1), zeros(0, 1)));

            ip = uipanel(right, Title="cubegui.lua on the Cube", Visible=obj.Level >= 2);
            ig = uigridlayout(ip, [2 1], RowHeight={28, "1x"}, Padding=[6 4 6 4]);
            obj.InstallButton = uibutton(ig, Text="Copy cubegui.lua to the Cube...", ...
                ButtonPushedFcn=@(~, ~) obj.guard(@() obj.installPressed()));
            obj.InstallLabel = uilabel(ig, WordWrap="on", Text=['Copies lua/cubegui.lua to ' ...
                'APM/scripts on the SD card, then restarts the Cube''s scripts.']);

            fp = uipanel(right, Title="Firmware over USB", Visible=obj.Level >= 1);
            fg = uigridlayout(fp, [2 1], RowHeight={28, "1x"}, Padding=[6 4 6 4]);
            fb = uigridlayout(fg, [1 2], Padding=[0 0 0 0]);
            obj.FlashButton = uibutton(fb, Text="Flash ArduPlane...", ...
                ButtonPushedFcn=@(~, ~) obj.guard(@() obj.flashPressed()));
            uibutton(fb, Text="Reset to a fresh Cube...", ...
                ButtonPushedFcn=@(~, ~) obj.guard(@() obj.resetPressed()));
            obj.FlashLabel = uilabel(fg, WordWrap="on", ...
                Text="Needs the USB cable. Flash keeps the Cube's settings; Reset erases them all.", ...
                Tooltip=['Flash installs the latest stable ArduPlane through the USB cable, as ' ...
                'Mission Planner''s Install Firmware does, and keeps the Cube''s settings. Reset ' ...
                'puts every setting back to its default, calibrations included, as flashing Sub ' ...
                'then Plane does. Both ask first.']);

            sp = uipanel(right, Title="Safety switch");
            sg = uigridlayout(sp, [1 1], Padding=[6 4 6 4]);
            uilabel(sg, WordWrap="on", Text=['After every reboot the Cube holds the servos ' ...
                'still until the safety switch is turned off. Use the button at the top of ' ...
                'the Run tab, or the button on the Cube. CubeGUI never arms the Cube.']);
        end

        % ---- Control callbacks -------------------------------------------------

        function guard(obj, action)
            % Run a button's action, showing any problem in the status line
            % instead of as a red error in the Command Window.
            try
                action();
            catch err
                obj.setStatus(err.message, true);
            end
        end

        function connectPressed(obj)
            if isempty(obj.Source)
                obj.connect();
            else
                obj.disconnect();
            end
        end

        function safetyPressed(obj)
            % Off if it's on or not known; on if it's off.
            obj.setSafety(isequal(obj.Telemetry.SafetyOn, false));
        end

        function addPressed(obj)
            name = obj.AddField.Value;
            if strlength(strtrim(name)) > 0
                obj.addParameter(name);
                obj.AddField.Value = "";
            end
        end

        function cellEdited(obj, event)
            % Someone typed in the "New value" column.
            name = obj.Checks(event.Indices(1)).name;
            text = strtrim(string(event.NewData));
            if text == ""
                obj.setNewValue(name, NaN);
                return
            end
            value = str2double(text);
            if isnan(value)
                obj.refreshParamTable();
                obj.setStatus("""" + text + """ isn't a number. Type a number, or clear the cell.", true);
                return
            end
            try
                obj.setNewValue(name, value);
            catch err
                obj.refreshParamTable();
                obj.setStatus(err.message, true);
                return
            end
            obj.setStatus(sprintf("%s will be set to %s when you click Apply.", name, ...
                showNumber(value)), false);
        end

        function laptopLogPressed(obj)
            % Start a new CSV file, or stop and save this one.
            if obj.Logger.IsLogging
                obj.LogWanted = false;
                obj.stopLogging();
            else
                obj.LogWanted = true;
                obj.startLogging();
            end
        end

        function cubeLogPressed(obj)
            % The Cube logs while disarmed only with LOG_DISARMED = 1, so
            % CubeGUI starts and stops its log by changing that, asking first.
            % ArduPilot has no command for it, and a Lua script can't do it.
            % Stopping pauses the log: the Cube carries on in the same .BIN
            % file when it starts again, and starts a new file at each power-up.
            now = obj.Telemetry.param("LOG_DISARMED");
            if isnan(now)
                obj.setStatus("CubeGUI hasn't read LOG_DISARMED from the Cube yet.", true);
                return
            end
            change = struct("name", "LOG_DISARMED", "from", now, "to", double(now == 0));
            if change.to == 1
                question = ["Start the Cube's own log?", "", "LOG_DISARMED:  0  →  1", "", ...
                    "The Cube saves this, so it keeps logging after a reboot until you stop it."];
            else
                question = ["Stop the Cube's own log?", "", ...
                    sprintf("LOG_DISARMED:  %s  →  0", showNumber(now))];
            end
            uiconfirm(obj.Figure, question, "Change a Cube parameter?", ...
                Options=["Write to Cube", "Cancel"], DefaultOption=1, CancelOption=2, ...
                CloseFcn=@(~, event) obj.confirmed(event.SelectedOption, change));
        end

        function downloadPressed(obj)
            % First ask the Cube for its list of logs; updateLogs asks
            % whether to download the newest once the list has arrived.
            requests = obj.Source.Logs.list();
            obj.Source.sendLogRequests(requests);
            obj.DownloadWaiting = true;
            obj.setStatus("Asking the Cube for its list of logs...", false);
        end

        function downloadConfirmed(obj, choice, entry)
            if choice ~= "Download" || isempty(obj.Source)
                obj.setStatus("Nothing downloaded.", false);
                return
            end
            file = fullfile(obj.Config.logging.folder, sprintf("Cube_log%d_%s.BIN", entry.id, ...
                string(datetime("now"), "yyyy-MM-dd_HH-mm-ss")));
            if ~isfolder(obj.Config.logging.folder)
                mkdir(obj.Config.logging.folder);
            end
            obj.Source.sendLogRequests(obj.Source.Logs.download(entry.id, entry.size, file));
            obj.setStatus("Downloading the Cube's log " + entry.id + "...", false);
        end

        function applyGains(obj)
            % Write the gains whose boxes differ from the Cube, after a
            % confirmation listing them (the same as the Setup tab's Apply).
            if isempty(obj.Source)
                obj.setStatus("Connect first.", true);
                return
            end
            changes = struct("name", {}, "from", {}, "to", {});
            lines = strings(1, 0);
            for k = 1:numel(obj.GainNames)
                now = obj.Telemetry.param(obj.GainNames(k));
                wanted = obj.GainBoxes(k).Value;
                if ~isnan(now) && abs(wanted - now) > 1e-6
                    changes(end+1) = struct("name", obj.GainNames(k), "from", now, "to", wanted); %#ok<AGROW>
                    lines(end+1) = sprintf("%s:  %s  →  %s", obj.GainNames(k), showNumber(now), ...
                        showNumber(wanted)); %#ok<AGROW>
                end
            end
            if isempty(changes)
                obj.setStatus("The gains are already those values.", false);
                return
            end
            uiconfirm(obj.Figure, ["CubeGUI will write these to the Cube:", "", lines, "", ...
                "The closed loop uses them straight away."], "Change the closed-loop gains?", ...
                Options=["Write to Cube", "Cancel"], DefaultOption=1, CancelOption=2, ...
                CloseFcn=@(~, event) obj.confirmed(event.SelectedOption, changes));
        end

        function installPressed(obj)
            % Copy lua/cubegui.lua onto the Cube (MAVFTP), after asking.
            if isempty(obj.Source) || ~isa(obj.Source, "CubeSource")
                obj.setStatus("Connect to a real Cube to install the script.", true);
                return
            end
            if obj.Telemetry.param("SCR_ENABLE") ~= 1
                obj.setStatus("Set SCR_ENABLE to 1 and reboot the Cube first, so it runs scripts.", true);
                return
            end
            file = fullfile(fileparts(mfilename("fullpath")), "..", "lua", "cubegui.lua");
            path = obj.Source.ScriptFolder + "/cubegui.lua";
            info = dir(file);
            uiconfirm(obj.Figure, [sprintf("Copy lua/cubegui.lua (%.1f kB) to %s on the Cube?", ...
                info.bytes / 1000, path), "", ...
                "It replaces any cubegui.lua already there, then restarts the Cube's scripts.", ...
                "If avdasi2.lua (guide page 06c) is there too, remove it: use one script, not both."], ...
                "Install cubegui.lua?", Options=["Copy to Cube", "Cancel"], DefaultOption=1, ...
                CancelOption=2, CloseFcn=@(~, event) obj.installConfirmed(event.SelectedOption, file, path));
        end

        function installConfirmed(obj, choice, file, path)
            if choice ~= "Copy to Cube" || isempty(obj.Source)
                obj.setStatus("Nothing copied.", false);
                return
            end
            f = fopen(file);
            closeIt = onCleanup(@() fclose(f));
            data = fread(f, Inf, "*uint8");
            clear closeIt
            obj.Source.sendFtp(obj.Source.Upload.start(path, data));
            obj.setStatus("Copying cubegui.lua to the Cube...", false);
        end

        function rebootPressed(obj)
            if isempty(obj.Source)
                obj.setStatus("Connect first.", true);
                return
            end
            uiconfirm(obj.Figure, ["Reboot the Cube?", "", ...
                "It restarts as if powered off and on, and CubeGUI reconnects by itself. " + ...
                "Afterwards the safety switch is on again, so the servos are held still until you turn it off.", "", ...
                "Don't reboot while the tunnel is running: the servos stop being driven during the restart."], ...
                "Reboot the Cube?", Options=["Reboot", "Cancel"], DefaultOption=2, CancelOption=2, ...
                Icon="warning", CloseFcn=@(~, event) obj.rebootConfirmed(event.SelectedOption));
        end

        function rebootConfirmed(obj, choice)
            if choice ~= "Reboot" || isempty(obj.Source)
                obj.setStatus("Not rebooted.", false);
                return
            end
            obj.Source.reboot();
            obj.setStatus("Rebooting the Cube...", false);
        end

        function checkRebootAfter(obj)
            % A reboot asked for after writing SCR_ENABLE (say) goes once the
            % Cube has confirmed every one of those writes.
            if isempty(obj.RebootAfter) || isempty(obj.Source)
                return
            end
            for r = obj.RebootAfter
                if ~isequal(obj.Telemetry.param(r.name), r.value)
                    if ~ismember(r.name, [obj.Writes.name])   % gave up writing it
                        obj.RebootAfter = obj.RebootAfter([]);
                        obj.setStatus("Not rebooting: the Cube didn't confirm " + r.name + ".", true);
                    end
                    return
                end
            end
            obj.RebootAfter = obj.RebootAfter([]);
            obj.Source.reboot();
            obj.setStatus("Rebooting the Cube...", false);
        end

        function flashPressed(obj)
            % Flash ArduPlane over USB (FirmwareUpload). First: which firmware?
            uiconfirm(obj.Figure, ["Flash ArduPlane onto the Cube, through its USB cable?", "", ...
                "CubeGUI can download the latest stable ArduPlane for your Cube from " + ...
                "firmware.ardupilot.org (this needs the internet), or use an .abin file you choose.", ...
                "The Cube's parameters are normally kept."], "Flash firmware", ...
                Options=["Download latest", "Choose a file...", "Cancel"], DefaultOption=1, ...
                CancelOption=3, CloseFcn=@(~, event) obj.guard(@() obj.firmwareChosen(event.SelectedOption)));
        end

        function firmwareChosen(obj, choice)
            % Then get the Cube into its bootloader, and find it.
            if choice == "Cancel"
                return
            end
            file = "";
            if choice == "Choose a file..."
                [name, folder] = uigetfile("*.abin", "Choose an ArduPilot firmware file (.abin)");
                figure(obj.Figure);   % uigetfile can leave CubeGUI behind other windows
                if isequal(name, 0)
                    return
                end
                file = string(fullfile(folder, name));
                FirmwareUpload.readAbin(file);   % check it's an .abin before going on
            end
            if isa(obj.Source, "CubeSource")
                % Connected: ask ArduPilot to restart into its bootloader and stay there.
                obj.Source.reboot(true);
                pause(0.5)
                obj.disconnect();
                obj.findBootloader(file);
            else
                uiconfirm(obj.Figure, ["Unplug the Cube's USB cable, click OK, then plug it back in.", ...
                    "", "Its bootloader only waits a few seconds after power-up for CubeGUI to find it."], ...
                    "Flash firmware", Options=["OK", "Cancel"], DefaultOption=1, CancelOption=2, ...
                    CloseFcn=@(~, event) obj.guard(@() obj.replugged(event.SelectedOption, file)));
            end
        end

        function replugged(obj, choice, file)
            if choice == "OK"
                obj.findBootloader(file);
            end
        end

        function findBootloader(obj, file)
            % Try each USB port until a bootloader answers (for up to 30 s),
            % then work out which firmware to flash, and ask before flashing.
            dlg = uiprogressdlg(obj.Figure, Title="Flash firmware", Indeterminate="on", ...
                Cancelable="on", Message="Looking for the Cube's bootloader on USB...");
            closeDlg = onCleanup(@() delete(dlg));
            up = [];
            started = tic;
            while isempty(up) && toc(started) < 30 && ~dlg.CancelRequested
                for port = usbPorts()
                    try
                        candidate = FirmwareUpload(port);
                        info = candidate.identify(1);
                        up = candidate;
                        break
                    catch
                        candidate = [];   % not a bootloader (yet): close it and carry on
                    end
                end
                pause(0.3)
            end
            if isempty(up)
                obj.setStatus("No Cube bootloader found on USB. Check the cable, and try again.", true);
                return
            end

            if file == ""
                if info.boardName == ""
                    up.restart();
                    obj.setStatus(sprintf("This board (ID %d) isn't a kit's Cube, so CubeGUI " + ...
                        "doesn't know which firmware to download. Choose a file instead.", info.boardId), true);
                    return
                end
                dlg.Message = "Downloading the latest stable ArduPlane for the " + info.boardName + "...";
                url = "https://firmware.ardupilot.org/Plane/stable/" + info.boardName + "/arduplane.abin";
                file = string(fullfile(tempdir, "arduplane_" + info.boardName + ".abin"));
                try
                    websave(file, url, weboptions(Timeout=60));
                catch err
                    up.restart();
                    obj.setStatus("Couldn't download the firmware: " + err.message, true);
                    return
                end
                what = "the latest stable ArduPlane for the " + info.boardName + " (from firmware.ardupilot.org)";
            else
                [~, name, ext] = fileparts(file);
                what = name + ext;
            end
            fw = FirmwareUpload.readAbin(file);
            board = info.boardName;
            if board == ""
                board = "an unknown board";
            end
            question = [sprintf("Flash %s onto this Cube (%s, board ID %d)?", what, board, info.boardId), "", ...
                "The old firmware is erased first. It takes a minute or so: don't unplug the cable until it's finished."];
            if what ~= "" && ~startsWith(what, "the latest")
                question = [question, "", "CubeGUI can't check that a file is for this board: make sure it is."];
            end
            clear closeDlg
            uiconfirm(obj.Figure, question, "Flash firmware", Options=["Flash", "Cancel"], ...
                DefaultOption=2, CancelOption=2, Icon="warning", ...
                CloseFcn=@(~, event) obj.guard(@() obj.flashConfirmed(event.SelectedOption, up, fw)));
        end

        function resetPressed(obj)
            % Every parameter back to its default: set FORMAT_VERSION to 0
            % and reboot. ArduPilot sees the wrong format version as it
            % starts and erases all its stored settings (AP_Vehicle/
            % Parameters.cpp, load_parameters), which is also why the
            % guide's "flash Sub, then Plane" resets a Cube.
            if isempty(obj.Source)
                obj.setStatus("Connect to the Cube first.", true);
                return
            end
            uiconfirm(obj.Figure, ["Reset the Cube to fresh: every setting back to its default?", "", ...
                "This erases everything stored on the Cube: servo limits, SERVOn_FUNCTION, " + ...
                "calibrations, SCR_ENABLE and LOG_DISARMED. The Cube then restarts.", "", ...
                "Lua scripts stay on the SD card but don't run, because scripting is off again " + ...
                "(SCR_ENABLE = 0). The telemetry settings go back to their defaults, which suit the Kahuna.", "", ...
                "Afterwards, set the Cube up again as in the step-by-step guide, and the Setup tab."], ...
                "Reset to a fresh Cube?", Options=["Reset", "Cancel"], DefaultOption=2, CancelOption=2, ...
                Icon="warning", CloseFcn=@(~, event) obj.guard(@() obj.resetConfirmed(event.SelectedOption)));
        end

        function resetConfirmed(obj, choice)
            if choice ~= "Reset" || isempty(obj.Source)
                obj.setStatus("Nothing reset.", false);
                return
            end
            obj.writeParams(struct("name", "FORMAT_VERSION", "from", NaN, "to", 0));
            obj.RebootAfter = struct("name", "FORMAT_VERSION", "value", 0);   % then reboot
            obj.setStatus("Resetting: the Cube restarts once it has confirmed, with every " + ...
                "setting at its default.", false);
        end

        function flashConfirmed(obj, choice, up, fw)
            if choice ~= "Flash"
                up.restart();   % back to the firmware it had
                delete(up)
                obj.setStatus("Nothing flashed. The Cube restarts with its old firmware.", false);
                return
            end
            dlg = uiprogressdlg(obj.Figure, Title="Flash firmware", Message="Starting...");
            closeDlg = onCleanup(@() delete(dlg));
            try
                up.flash(fw.image, @(fraction, text) showProgress(dlg, fraction, text));
                showText(obj.FlashLabel, "Flashed. The Cube restarts with the new firmware: connect again.");
                obj.setStatus("Firmware flashed. Connect again once the Cube has restarted.", false);
            catch err
                showText(obj.FlashLabel, "Not flashed: " + err.message);
                obj.setStatus("Firmware not flashed: " + err.message + " Flash again to put it right.", true);
            end
            delete(up)
        end

        function cancelDownloadPressed(obj)
            obj.Source.sendLogRequests(obj.Source.Logs.cancel());
            obj.setStatus("Download cancelled. The Cube carries on logging as before.", false);
        end

        % ---- Display -----------------------------------------------------------

        function updateConnectionControls(obj)
            connected = ~isempty(obj.Source);
            isCube = obj.SourceDropDown.Value == "Cube (Wi-Fi)";
            isUsb = obj.SourceDropDown.Value == "Cube (USB)";
            if connected
                obj.ConnectButton.Text = "Disconnect";
            else
                obj.ConnectButton.Text = "Connect";
            end
            obj.SourceDropDown.Enable = ~connected;
            for field = [obj.AddressField, obj.CubePortField, obj.LocalPortField]
                field.Enable = ~connected && isCube;
            end
            % Over USB there's no address or UDP ports: a USB port instead.
            obj.AddressField.Visible = ~isUsb;
            set(obj.UdpControls, Visible=~isUsb);
            obj.SerialDropDown.Visible = isUsb;
            obj.SerialDropDown.Enable = ~connected;
            obj.AddressLabel.Text = string(ifElse(isUsb, "USB port", "Cube address"));
        end

        function sourceChanged(obj)
            % Choosing Cube (USB) looks at the USB ports, to say which one is MAVLink.
            obj.updateConnectionControls();
            if obj.SourceDropDown.Value == "Cube (USB)" && isempty(obj.Source)
                obj.setStatus("Looking at the USB ports...", false);
                drawnow
                [labels, ports, best] = labelUsbPorts();
                inUse = any(endsWith(labels, "(in use)"));
                if isempty(ports)
                    obj.SerialDropDown.Items = "(none found)";
                    obj.SerialDropDown.ItemsData = "";
                    obj.setStatus("No USB port found. Plug in the Cube's USB cable, " + ...
                        "then choose Cube (USB) again.", true);
                    return
                end
                obj.SerialDropDown.Items = labels;
                obj.SerialDropDown.ItemsData = ports;
                obj.SerialDropDown.Value = ports(best);
                obj.SerialDropDown.Tooltip = labels(best);
                if inUse
                    obj.setStatus("A USB port is in use by another program: is another CubeGUI " + ...
                        "window or Mission Planner open? Close it, then choose Cube (USB) again.", true);
                else
                    obj.setStatus("Choose the USB port marked MAVLink, and click Connect.", false);
                end
            end
        end

        function setStatus(obj, text, isProblem)
            showText(obj.StatusLabel, text);
            if isProblem
                obj.StatusLabel.FontColor = [0.9 0.1 0.1];
            else
                % Hand the colour back to MATLAB's theme, so the text is
                % readable in both light and dark mode.
                obj.StatusLabel.FontColorMode = "auto";
            end
        end

        function redraw(obj)
            % Runs 10 times a second. Reads Telemetry and updates the window.
            try
                obj.RedrawCount = obj.RedrawCount + 1;
                obj.updateLamp();
                obj.Cube.tick();       % servo limits, and commands held back by the rate limit
                obj.updatePanels();
                obj.updateLogLabel();
                obj.updateLogs();
                obj.updateGains();
                obj.updateInstall();
                obj.updateSafety();
                obj.checkAcks();
                obj.checkWrites();
                obj.checkRebootAfter();
                obj.checkReboot();
                % The Setup tab changes slowly, so once a second is plenty,
                % and only while it's showing: updating its tables is slow
                % enough (tenths of a second) to hold up everything else.
                if mod(obj.RedrawCount, 10) == 0 && isequal(obj.Tabs.SelectedTab, obj.SetupTab)
                    obj.updateSetupTab();
                end
                drawnow limitrate
            catch err
                % Report but keep going: a timer that errors stops for good.
                fprintf(2, "CubeGUI redraw: %s%s\n", err.message, whereFrom(err));
            end
        end

        function checkReboot(obj)
            % If the Cube rebooted while connected, say so: its safety switch
            % is back on, and its parameters may have changed, so read them again.
            tel = obj.Telemetry;
            if tel.RebootCount == obj.RebootsSeen || isempty(obj.Source)
                return
            end
            obj.RebootsSeen = tel.RebootCount;
            tel.forgetParams(obj.parametersToRead());
            obj.askFor(obj.parametersToRead());
            obj.setStatus(['The Cube restarted. Its safety switch is on again, so turn ' ...
                'it off before moving the servos.'], true);
        end

        function updateLamp(obj)
            if isempty(obj.Source)
                obj.Lamp.Color = [0.6 0.6 0.6];
                obj.LampLabel.Text = "Not connected";
                return
            end
            age = obj.Telemetry.secondsSinceHeartbeat();
            if age < obj.HeartbeatTimeout
                obj.Lamp.Color = [0 0.75 0];
                obj.LampLabel.Text = "Connected";
            elseif obj.Telemetry.HeartbeatCount == 0 && toc(obj.ConnectTic) < 3
                obj.Lamp.Color = [1 0.7 0];
                obj.LampLabel.Text = "Waiting for the Cube...";
            elseif obj.Telemetry.HeartbeatCount == 0
                obj.Lamp.Color = [0.85 0 0];
                obj.LampLabel.Text = "No heartbeat";
                obj.setStatus(['Nothing heard from the Cube. Check the laptop is on the kit''s ' ...
                    'Wi-Fi (AVDASI2 - Kit X), the Cube is powered, and the ports are right.'], true);
            else
                obj.Lamp.Color = [0.85 0 0];
                obj.LampLabel.Text = sprintf("No heartbeat for %.0f s", age);
            end
        end

        function updatePanels(obj)
            % Each panel's update, 10 times a second. One that errors is
            % switched off, and its space says what went wrong; the others
            % carry on.
            for k = 1:numel(obj.Panels)
                p = obj.Panels(k);
                if p.failed
                    continue
                end
                try
                    p.update();
                catch err
                    obj.Panels(k).failed = true;
                    showPanelProblem(p.holder, sprintf("%s.m stopped updating: %s%s", p.name, ...
                        err.message, panelLine(err, p.name)));
                end
            end
        end

        function updateLogLabel(obj)
            if obj.Logger.IsLogging
                [~, name, ext] = fileparts(obj.Logger.File);
                showText(obj.LogLabel, sprintf("Logging to %s%s (%d rows)", name, ext, obj.Logger.RowCount));
            end
        end

        function updateLogs(obj)
            % The Logs panel: what each log is doing, and the download.
            if obj.Level < 1
                return
            end
            connected = ~isempty(obj.Source);
            obj.LaptopLogButton.Enable = connected;
            if obj.Logger.IsLogging
                obj.LaptopLogButton.Text = "Stop";
                obj.LaptopLogLabel.Text = sprintf("CSV: logging, %d rows", obj.Logger.RowCount);
            else
                obj.LaptopLogButton.Text = "Start";
                obj.LaptopLogLabel.Text = string(ifElse(connected, "CSV: not logging", "CSV: connect first"));
            end

            cubeLog = NaN;
            if connected
                cubeLog = obj.Telemetry.param("LOG_DISARMED");
            end
            obj.CubeLogButton.Enable = ~isnan(cubeLog);
            if ~connected
                obj.CubeLogButton.Text = "Start";
                obj.CubeLogLabel.Text = ".BIN: connect first";
            elseif isnan(cubeLog)
                obj.CubeLogLabel.Text = ".BIN: reading LOG_DISARMED...";
            elseif cubeLog >= 1
                obj.CubeLogButton.Text = "Stop";
                obj.CubeLogLabel.Text = ".BIN: recording on the Cube";
            else
                obj.CubeLogButton.Text = "Start";
                obj.CubeLogLabel.Text = ".BIN: not recording";
            end

            % Downloading needs a real Cube, and its log stopped (so the
            % file isn't still growing).
            if ~connected || ~isa(obj.Source, "CubeSource")
                obj.DownloadButton.Enable = "off";
                obj.CancelButton.Visible = "off";
                showText(obj.DownloadLabel, string(ifElse(connected, ...
                    "Downloading needs a real Cube.", "")));   % not the Simulated one
                return
            end
            logs = obj.Source.Logs;
            obj.Source.sendLogRequests(logs.tick());
            busy = ismember(logs.State, ["listing", "downloading"]);
            obj.DownloadButton.Enable = ~busy && cubeLog == 0;
            obj.CancelButton.Visible = busy;
            switch logs.State
                case "listing"
                    showText(obj.DownloadLabel, "Listing the Cube's logs...");
                case "listed"
                    if obj.DownloadWaiting
                        obj.DownloadWaiting = false;
                        obj.askToDownload(logs.newest());
                    end
                    showText(obj.DownloadLabel, "");
                case "downloading"
                    left = logs.secondsLeft();
                    text = sprintf("Log %d: %.0f %% of %.1f MB", logs.Id, 100 * logs.progress(), ...
                        logs.Size / 1e6);
                    if ~isnan(left)
                        text = text + sprintf(", about %.0f min left", ceil(left / 60));
                    end
                    showText(obj.DownloadLabel, text);
                case "done"
                    [~, name, ext] = fileparts(logs.File);
                    showText(obj.DownloadLabel, "Saved " + name + ext + " in the logs folder.");
                case "failed"
                    showText(obj.DownloadLabel, "Download failed: " + logs.Message);
                case "cancelled"
                    showText(obj.DownloadLabel, "Download cancelled.");
                otherwise
                    showText(obj.DownloadLabel, string(ifElse(cubeLog == 0, "", ...
                        "Stop the Cube's log to download it.")));
            end
        end

        function updateGains(obj)
            % Show the Cube's gains in the boxes, except one someone is
            % changing (its value differs from what was last shown).
            if obj.Level < 3
                return
            end
            for k = 1:numel(obj.GainNames)
                box = obj.GainBoxes(k);
                now = NaN;
                if ~isempty(obj.Source)
                    now = obj.Telemetry.param(obj.GainNames(k));
                end
                box.Enable = ~isnan(now);
                edited = ~isnan(obj.GainShown(k)) && abs(box.Value - obj.GainShown(k)) > 1e-6;
                if ~isnan(now) && ~edited && ~isequal(now, obj.GainShown(k))
                    box.Value = now;
                    obj.GainShown(k) = now;
                elseif ~isnan(now) && edited && abs(box.Value - now) < 1e-6
                    obj.GainShown(k) = now;   % the Cube now has the typed value
                end
            end
        end

        function updateInstall(obj)
            % The script install's progress, and restarting the scripts once
            % it's copied.
            if obj.Level < 2 || isempty(obj.Source) || ~isa(obj.Source, "CubeSource")
                return
            end
            up = obj.Source.Upload;
            was = up.State;
            obj.Source.sendFtp(up.tick());
            switch up.State
                case "uploading"
                    obj.InstallButton.Enable = "off";
                    showText(obj.InstallLabel, sprintf("Copying: %.0f %%", 100 * up.progress()));
                case "done"
                    obj.InstallButton.Enable = "on";
                    if was == "uploading"
                        obj.Source.restartScripts();
                        showText(obj.InstallLabel, "Copied, and the Cube's scripts restarted. " + ...
                            "Who's in charge should say ""Script running"" within a few seconds.");
                        obj.setStatus("cubegui.lua copied to the Cube.", false);
                    end
                case "failed"
                    obj.InstallButton.Enable = "on";
                    if was == "uploading"
                        showText(obj.InstallLabel, "Not copied: " + up.Message);
                        obj.setStatus("cubegui.lua wasn't copied: " + up.Message, true);
                    end
            end
        end

        function askToDownload(obj, entry)
            if isempty(entry) || entry.size == 0
                obj.setStatus("The Cube has no logs to download.", false);
                return
            end
            % The Kahuna's link runs at 57600 baud: about 4 kB a second
            % once CubeGUI's own telemetry is taken out. (Timed on a kit on
            % 3 November: 0.5 MB in 2 minutes 3 seconds.)
            % Over USB ArduPilot sends logs far faster (AP_Logger_MAVLinkLogTransfer.cpp).
            if obj.Source.SerialPort ~= ""
                speed = "Over USB this is much quicker than over the Wi-Fi. " + ...
                    "The Logs panel shows the time left once it starts.";
            else
                minutes = entry.size / 4000 / 60;
                speed = sprintf(['Over the Wi-Fi this could take about %.0f minutes. ' ...
                    'A USB cable is much faster.'], max(1, ceil(minutes)));
            end
            uiconfirm(obj.Figure, [sprintf("Download the Cube's newest log (number %d, %.1f MB)?", ...
                entry.id, entry.size / 1e6), "", speed, "", ...
                "The Cube doesn't log while it sends a log."], "Download the Cube's log?", ...
                Options=["Download", "Cancel"], DefaultOption=1, CancelOption=2, ...
                CloseFcn=@(~, event) obj.downloadConfirmed(event.SelectedOption, entry));
        end

        function checkAcks(obj)
            % If the Cube refused a servo command, say why in plain English.
            tel = obj.Telemetry;
            if tel.AckCount == obj.AcksSeen
                return
            end
            obj.AcksSeen = tel.AckCount;
            if tel.LastAck.command == obj.DoSetServo && tel.LastAck.result ~= 0
                obj.setStatus(['The Cube refused a servo command. That output''s ' ...
                    'SERVOn_FUNCTION probably isn''t 0: see the Setup tab.'], true);
            end
        end

        function updateSafety(obj)
            connected = ~isempty(obj.Source);
            obj.SafetyButton.Enable = connected;
            state = obj.Telemetry.SafetyOn;
            if ~connected
                obj.SafetyLamp.Color = [0.6 0.6 0.6];
                obj.SafetyLabel.Text = "Safety switch: not connected";
                obj.SafetyButton.Text = "Turn off";
            elseif isnan(state)
                obj.SafetyLamp.Color = [0.6 0.6 0.6];
                obj.SafetyLabel.Text = "Safety switch: not reported yet";
                obj.SafetyButton.Text = "Turn off";
            elseif state
                obj.SafetyLamp.Color = [1 0.7 0];
                obj.SafetyLabel.Text = "Safety switch ON: servos held still";
                obj.SafetyButton.Text = "Turn off";
            else
                obj.SafetyLamp.Color = [0 0.75 0];
                obj.SafetyLabel.Text = "Safety switch OFF: servos live";
                obj.SafetyButton.Text = "Turn on";
            end

            % Report how a request went.
            r = obj.SafetyRequest;
            if isempty(r) || ~connected
                return
            end
            if isequal(state, r.wanted)
                obj.setStatus("The safety switch is now " + string(ifElse(r.wanted, ...
                    "on: servos held still.", "off: servos live.")), false);
                obj.SafetyRequest = [];
            elseif toc(r.tic) > 5
                obj.setStatus(['The Cube didn''t change its safety switch. Try the button ' ...
                    'on the Cube, or Mission Planner (Ctrl+F, Toggle Saftey Switch).'], true);
                obj.SafetyRequest = [];
            end
        end

        function tabChanged(obj)
            % Bring the Setup tab up to date as soon as it's shown.
            if isequal(obj.Tabs.SelectedTab, obj.SetupTab)
                obj.updateSetupTab();
            end
        end

        function updateSetupTab(obj)
            tel = obj.Telemetry;
            obj.refreshParamTable();
            if ~isequal(tel.Version, obj.VersionShown) || isempty(tel.Version)
                obj.VersionShown = tel.Version;
                obj.showVersion();
            end
            names = keys(tel.NamedValues);
            if isempty(names)
                lua = table(strings(0, 1), zeros(0, 1));
            else
                lua = table(names, values(tel.NamedValues));
            end
            setIfChanged(obj.LuaTable, lua);
        end

        function checkWrites(obj)
            % For each parameter written: has the Cube confirmed it? If not,
            % send it again (Wi-Fi can lose a message), up to three times.
            if isempty(obj.Source)
                return
            end
            keep = true(1, numel(obj.Writes));
            for k = 1:numel(obj.Writes)
                w = obj.Writes(k);
                value = obj.Telemetry.param(w.name);
                if sameValue(value, w.value)
                    keep(k) = false;
                    if isKey(obj.Edits, w.name)
                        obj.Edits(w.name) = [];
                    end
                    obj.setStatus(sprintf("The Cube confirmed %s = %s.", w.name, showNumber(w.value)), false);
                elseif toc(w.tic) > 1.5 && w.tries < 3
                    obj.Source.setParam(w.name, w.value);
                    obj.Writes(k).tic = tic;
                    obj.Writes(k).tries = w.tries + 1;
                elseif toc(w.tic) > 1.5
                    keep(k) = false;
                    obj.setStatus(sprintf(['The Cube didn''t accept %s = %s (it still says %s). ' ...
                        'The value may be out of range for that parameter.'], w.name, ...
                        showNumber(w.value), showNumber(value)), true);
                end
            end
            if ~all(keep)
                obj.Writes = obj.Writes(keep);
                obj.refreshParamTable();
            end
        end

        function refreshParamTable(obj)
            % Working out the rows is quick; putting them in the table isn't,
            % so only do that when something has changed.
            setIfChanged(obj.ParamTable, obj.paramRows());
        end

        function rows = paramRows(obj)
            % The Setup table's contents: one row per parameter.
            n = numel(obj.Checks);
            current = strings(n, 1);
            next = strings(n, 1);
            status = strings(n, 1);
            now = obj.Telemetry.laptopTime();
            writing = string([obj.Writes.name]);
            for k = 1:n
                c = obj.Checks(k);
                value = obj.Telemetry.param(c.name);
                target = obj.newValue(c, value);
                if ~isnan(target)
                    next(k) = showNumber(target);
                end
                if isempty(obj.Source)
                    current(k) = "-";
                    status(k) = "Not connected";
                elseif isnan(value)
                    asked = isKey(obj.AskedAt, c.name) && now - obj.AskedAt(c.name) > 8;
                    current(k) = ifElse(asked, "-", "...");
                    status(k) = ifElse(asked, "Not on this Cube", "Reading...");
                else
                    current(k) = showNumber(value);
                    if ismember(c.name, writing)
                        status(k) = "Writing...";
                    elseif ~isnan(target) && ~sameValue(target, value)
                        status(k) = ifElse(isKey(obj.Edits, c.name), "Changed: Apply", "Needs changing");
                    elseif c.readOnly
                        status(k) = "Read-only";
                    elseif ~c.isOk(value)
                        status(k) = "Out of range";
                    elseif ~isnan(c.wanted)
                        status(k) = "OK";
                    else
                        status(k) = "";
                    end
                end
            end
            rows = table([obj.Checks.group]', [obj.Checks.name]', current, next, status, ...
                [obj.Checks.why]');
        end

        function showVersion(obj)
            v = obj.Telemetry.Version;
            L = obj.VersionLabels;
            if isempty(v)
                for f = string(fieldnames(L))'
                    L.(f).Text = "-";
                end
                return
            end
            vehicles = dictionary([1 2 12 13], ["ArduPlane (fixed-wing)", "ArduCopter", ...
                "ArduSub", "ArduCopter (hexa)"]);
            type = obj.Telemetry.VehicleType;
            if isKey(vehicles, type)
                L.vehicle.Text = vehicles(type);
            elseif isnan(type)
                L.vehicle.Text = "-";
            else
                L.vehicle.Text = "MAV_TYPE " + type;
            end
            L.firmware.Text = v.firmware;
            L.git.Text = v.git;
            L.board.Text = v.board;
            L.uid.Text = v.uid;
        end
    end
end

% ---- Helpers ----------------------------------------------------------------

function setIfChanged(uiTable, data)
% Give a uitable new contents only if they differ from what it shows.
if ~isequal(uiTable.Data, data)
    uiTable.Data = data;
end
end

function text = whereFrom(err)
% " (in updatePlots, line 721)": where an error happened, for the Command Window.
text = "";
if ~isempty(err.stack)
    text = sprintf(" (in %s, line %d)", err.stack(1).name, err.stack(1).line);
end
end

function text = showNumber(v)
% Parameter values without float noise: 0.1 rather than 0.100000001.
text = string(sprintf("%.7g", v));
end

function tf = sameValue(a, b)
% The Cube stores parameters as 32-bit floats, so compare with a little slack.
tf = ~isnan(a) && ~isnan(b) && abs(a - b) <= 1e-6 * max(1, abs(b));
end

function showProgress(dlg, fraction, text)
% Update a progress dialog: a bar for a fraction, or "busy" for NaN.
dlg.Indeterminate = isnan(fraction);
if ~isnan(fraction)
    dlg.Value = fraction;
end
dlg.Message = text;
drawnow limitrate
end

function position = windowPosition(width, height)
% A window of this size, made smaller if need be to fit on the screen with
% its title bar showing. On a laptop with its display scaled to 150 %, the
% screen is only about 1280 x 720 in MATLAB's pixels, and a window placed
% off the top can't be dragged back.
screen = get(groot, "ScreenSize");   % [left bottom width height]
margin = [20 50 20 40];              % left, bottom (a taskbar), right, top (a title bar)
width = min(width, screen(3) - margin(1) - margin(3));
height = min(height, screen(4) - margin(2) - margin(4));
left = screen(1) + max(margin(1), round((screen(3) - width) / 2));
bottom = screen(2) + max(margin(2), round((screen(4) - height) / 2));
position = [left bottom width height];
end

function ports = usbPorts()
% The serial ports a Cube's USB cable could be on, as a string array,
% lowest-numbered first (COM3 before COM10).
%
% Each system names a USB serial device like the Cube its own way, whatever
% hub or dongle it's plugged into: /dev/cu.usbmodem... on a Mac, /dev/ttyACM...
% on Linux, and COMn on Windows. On a Mac and Linux that's enough to leave
% out Bluetooth speakers and headphones, which have serial ports named after
% themselves (/dev/cu.JBLCharge5, say). A Mac also lists every device twice,
% as /dev/cu.* and /dev/tty.*; the cu one is for programs that start the
% conversation. Windows names give no clue, so all its COM ports are listed,
% and listening for MAVLink (labelUsbPorts) picks out the Cube.
%
% "all", not "available": "available" leaves out a port another program
% has open, so with a second CubeGUI window (or Mission Planner) holding the
% Cube's MAVLink port, only its other port was listed, and was guessed to
% be MAVLink. Listed, it's labelled "in use" instead (Robin, 4 November).
ports = serialportlist("all");
if ismac
    ports = ports(startsWith(ports, "/dev/cu.usbmodem"));
elseif isunix
    ports = ports(startsWith(ports, "/dev/ttyACM"));
end
[~, order] = sort(str2double(regexp(ports, "\d+$", "match", "once")));
ports = ports(order);
end

function [labels, ports, best] = labelUsbPorts()
% The USB ports, each labelled with whether ArduPilot's MAVLink is on it,
% and best, the one to choose. A Cube's USB cable carries two ports: the
% first is MAVLink, the second SLCAN, a CAN-bus link (ArduPilot's hwdef:
% OTG1 and OTG2). Other devices can add more: a USB-C dongle can have one
% of its own. CubeSource.findMavlink listens on them all for 1.5 s. If none
% is heard (the Cube still starting, say), guess the lowest-numbered port,
% which is the usual way round.
ports = usbPorts();
found = CubeSource.findMavlink(ports, 1.5);
labels = ports;
for k = 1:numel(ports)
    if found(k) ~= ""
        labels(k) = ports(k) + " (" + found(k) + ")";
    end
end
best = find(found == "MAVLink", 1);
if isempty(best)
    best = find(found ~= "in use", 1);   % never guess a port that's in use
    if isempty(best)
        best = 1;
    else
        labels(best) = ports(best) + " (probably MAVLink)";
    end
end
end

function showText(label, text)
% Show text in a label, and the same text when the mouse hovers over it,
% so a message too long for its space can still be read in full.
% Some of these update 10 times a second, so only change what's different.
if ~isequal(string(label.Text), string(text))
    label.Text = text;
    label.Tooltip = text;
end
end

function out = ifElse(condition, a, b)
% A one-line if/else, like Python's  a if condition else b.
if condition
    out = a;
else
    out = b;
end
end

function showPanelProblem(holder, text)
% Replace a panel with a red message saying what went wrong, and print it
% in the Command Window too, where it's easy to copy.
delete(holder.Children)
uilabel(holder, Text=text, WordWrap="on", FontColor=[0.9 0.1 0.1]);
fprintf(2, "CubeGUI: %s\n", text);
end

function text = panelLine(err, name)
% " (servoPanel.m, line 42)": the line in a panel's own file where an error
% happened, which is more use to a student than a line deep in MATLAB.
text = "";
for frame = reshape(err.stack, 1, [])
    [~, file] = fileparts(frame.file);
    if file == string(name)
        text = sprintf(" (%s.m, line %d)", name, frame.line);
        return
    end
end
end
