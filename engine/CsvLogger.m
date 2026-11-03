classdef CsvLogger < handle
    %CSVLOGGER  Writes the telemetry to a CSV file on the laptop, one row per pitch sample.
    %
    %   logger = CsvLogger(telemetry, servos, folder);
    %   logger = CsvLogger(telemetry, servos, folder, ["CG_MODE", "FLAP_V"]);  % also log these Lua values
    %   logger.start()     % new file, named by date and time; starts writing
    %   logger.stop()      % writes what's left and stops
    %
    %   Columns:
    %     utc_time          laptop's clock (UTC) when the sample arrived, e.g. 2026-10-20T14:03:27.123Z
    %     laptop_posix_s    the same time as seconds since 1 Jan 1970, easier for maths
    %     cube_time_ms      the Cube's own clock: milliseconds since it booted (time_boot_ms)
    %     pitch_deg
    %     pitch_rate_dps    how fast the pitch is changing, in degrees per second
    %     then for each servo in the settings, e.g. elevator:
    %       elevator_cmd_us   the PWM CubeGUI last sent (blank-ish NaN until something is sent)
    %       elevator_out_us   the PWM the Cube reported on that output
    %     then a column for each extra signal (a Lua value, by name): its
    %       latest value at or before that row's Cube time
    %     marker            a run marker's text, in the row where it was made (see Cube.mark).
    %                       The first row always says "log started": with text in
    %                       its first row, MATLAB's readtable reads the column as
    %                       text. (Empty there, it guesses numbers and loses the markers.)
    %
    %   Commands are sent on the laptop's clock, but the rows are on the
    %   Cube's. To put each command in the right row, the logger estimates
    %   the difference between the two clocks: the smallest gap seen between
    %   a sample's Cube time and the laptop time it arrived, which is the
    %   sample that was held up least. A command then goes in the first row
    %   at or after the Cube time it was sent. Before this, a command went
    %   in the first row to *arrive* after it, and with samples arriving
    %   seconds late (seen in the VM on 2026-10-31) it landed seconds early
    %   in Cube time.
    %
    %   This is the only file that knows the log format, so it can change
    %   later without touching anything else.
    %
    %   Message callbacks don't write to the file. They only store samples in
    %   Telemetry, and a timer here collects the new ones twice a second.
    %   Each time, the file is opened, added to and closed again, so if
    %   MATLAB or the laptop crashes, at most half a second is lost.

    properties (SetAccess = private)
        File = ""          % full path of the current log file
        RowCount = 0
        IsLogging = false
    end

    properties (Constant)
        WritePeriod = 0.5  % seconds between writes
    end

    properties (Access = private)
        Telemetry
        Servos             % the servos from the settings: name and output
        Extra = strings(1, 0)       % Lua values to log as well, by name
        MarkersWritten = 0          % how many of Telemetry.Markers are in the file
        Folder
        Timer
        LastCubeTime = -Inf         % Cube time of the last row written
        RebootsSeen = 0             % Telemetry.RebootCount as of the last write
        LastCommandTime = -Inf      % laptop time of the last command applied
        ClockOffset = Inf           % laptop time minus Cube time, the smallest seen (s)
        Commanded = NaN(1, 16)      % PWM last sent to each output, as of the last row
    end

    methods
        function obj = CsvLogger(telemetry, servos, folder, extraSignals)
            obj.Telemetry = telemetry;
            obj.Servos = servos;
            obj.Folder = string(folder);
            if nargin > 3
                obj.Extra = reshape(string(extraSignals), 1, []);
            end
        end

        function start(obj)
            if obj.IsLogging
                return
            end
            if ~isfolder(obj.Folder)
                mkdir(obj.Folder);
            end
            % Local time in the name, because that's what students will look
            % for; the rows themselves use UTC.
            name = "CubeGUI_" + string(datetime("now", Format="yyyy-MM-dd_HH-mm-ss")) + ".csv";
            obj.File = fullfile(obj.Folder, name);
            obj.RowCount = 0;
            obj.LastCubeTime = -Inf;
            obj.ClockOffset = Inf;
            obj.MarkersWritten = numel(obj.Telemetry.Markers);   % only markers made from now on
            obj.RebootsSeen = obj.Telemetry.RebootCount;
            obj.LastCommandTime = -Inf;
            obj.Commanded = NaN(1, 16);

            obj.append(obj.header() + newline);

            obj.Timer = timer(ExecutionMode="fixedSpacing", Period=obj.WritePeriod, ...
                BusyMode="drop", Name="CubeGUI logger", TimerFcn=@(~, ~) obj.writeNew());
            start(obj.Timer)
            obj.IsLogging = true;
        end

        function stop(obj)
            if ~isempty(obj.Timer) && isvalid(obj.Timer)
                stop(obj.Timer)
                delete(obj.Timer)
            end
            obj.Timer = [];
            if obj.IsLogging
                obj.writeNew();   % catch the last half second
            end
            obj.IsLogging = false;
        end

        function delete(obj)
            obj.stop();
        end

        function writeNew(obj)
            % Write every pitch sample that has arrived since the last write.
            try
                text = obj.newRows();
                if strlength(text) > 0
                    obj.append(text);
                end
            catch err
                % Keep going: a timer that errors stops for good.
                fprintf(2, "CubeGUI logger: %s\n", err.message);
            end
        end
    end

    methods (Access = private)
        function text = header(obj)
            names = ["utc_time", "laptop_posix_s", "cube_time_ms", "pitch_deg", "pitch_rate_dps"];
            for s = obj.Servos'
                base = matlab.lang.makeValidName(lower(s.name));
                names = [names, base + "_cmd_us", base + "_out_us"]; %#ok<AGROW>
            end
            names = [names, obj.Extra, "marker"];
            text = strjoin(names, ",");
        end

        function text = newRows(obj)
            tel = obj.Telemetry;
            [t, v] = tel.Pitch.data();
            text = "";
            if isempty(t)
                return
            end
            if tel.RebootCount ~= obj.RebootsSeen
                % The Cube rebooted, so its clock started again from 0.
                % Start counting again too.
                obj.RebootsSeen = tel.RebootCount;
                obj.LastCubeTime = -Inf;
                obj.ClockOffset = Inf;   % a new Cube clock, so a new difference
            end
            new = t > obj.LastCubeTime;
            if ~any(new)
                return
            end
            t = t(new);
            pitch = v(new, 1);
            arrival = v(new, 2);
            pitchRate = v(new, 3);

            [outT, outPwm] = tel.Outputs.data();
            [cmdT, cmd] = tel.Commands.data();
            pending = cmdT > obj.LastCommandTime;
            cmdT = cmdT(pending);
            cmd = cmd(pending, :);
            % When each command was sent, on the Cube's clock (see the top).
            obj.ClockOffset = min(obj.ClockOffset, min(arrival - t));
            cmdCubeT = cmdT - obj.ClockOffset;

            outputs = [obj.Servos.output];
            n = numel(t);
            servoCols = NaN(n, 2 * numel(outputs));
            next = 1;   % next command not yet applied
            for k = 1:n
                % Apply any commands sent at or before this sample's Cube time.
                while next <= numel(cmdT) && cmdCubeT(next) <= t(k)
                    obj.Commanded(cmd(next, 1)) = cmd(next, 2);
                    obj.LastCommandTime = cmdT(next);
                    next = next + 1;
                end
                % The latest output report at or before this sample's Cube time.
                j = find(outT <= t(k), 1, "last");
                for m = 1:numel(outputs)
                    servoCols(k, 2*m - 1) = obj.Commanded(outputs(m));
                    if ~isempty(j)
                        servoCols(k, 2*m) = outPwm(j, outputs(m));
                    end
                end
            end

            % Extra signals: each one's latest value at or before the row's Cube time.
            extraCols = NaN(n, numel(obj.Extra));
            for e = 1:numel(obj.Extra)
                buffer = tel.namedHistory(obj.Extra(e));
                if ~isempty(buffer)
                    [et, ev] = buffer.data();
                    for k = 1:n
                        j = find(et <= t(k), 1, "last");
                        if ~isempty(j)
                            extraCols(k, e) = ev(j);
                        end
                    end
                end
            end

            % Markers: each in the first row at or after the Cube time it was made.
            markerCol = strings(n, 1);
            while obj.MarkersWritten < numel(tel.Markers)
                marker = tel.Markers(obj.MarkersWritten + 1);
                k = find(t >= marker.time - obj.ClockOffset, 1);
                if isempty(k)
                    break    % made after the newest row so far: it goes in a later write
                end
                markerCol(k) = strtrim(markerCol(k) + " " + marker.text);
                obj.MarkersWritten = obj.MarkersWritten + 1;
            end
            if obj.RowCount == 0      % the file's first row: see the top
                markerCol(1) = strtrim("log started " + markerCol(1));
            end
            % In double quotes, with any double quotes inside doubled, so a
            % comma in the text can't split the column.
            hasMarker = markerCol ~= "";
            markerCol(hasMarker) = '"' + replace(markerCol(hasMarker), '"', '""') + '"';

            utc = datetime(arrival, ConvertFrom="posixtime", TimeZone="UTC", ...
                Format="yyyy-MM-dd'T'HH:mm:ss.SSS'Z'");
            % One line per sample. compose is like Python's % formatting,
            % applied to every row at once.
            numbers = [arrival, round(t * 1000), pitch, pitchRate, servoCols, extraCols];
            format = "%.3f,%d,%.3f,%.3f" + join(repmat(",%g", 1, size(servoCols, 2) + numel(obj.Extra)), "");
            lines = string(utc) + "," + compose(format, numbers) + "," + markerCol;
            text = join(lines, newline) + newline;

            obj.LastCubeTime = t(end);
            obj.RowCount = obj.RowCount + n;
        end

        function append(obj, text)
            % Open, add, close. Closing is what makes sure it's on disk.
            [fid, message] = fopen(obj.File, "a");
            if fid < 0
                error("CubeGUI:log", "Can't write to the log file %s: %s", obj.File, message)
            end
            closer = onCleanup(@() fclose(fid));
            fprintf(fid, "%s", text);
        end
    end
end
