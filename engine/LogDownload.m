classdef LogDownload < handle
    %LOGDOWNLOAD  Fetches one of the Cube's own logs (.BIN) over MAVLink.
    %
    %   Part of CubeGUI's engine. CubeSource owns one, and the window drives it.
    %
    %   This uses MAVLink's log protocol, the same one Mission Planner uses
    %   for "Download DataFlash Log Via Mavlink":
    %     LOG_REQUEST_LIST  ->  one LOG_ENTRY back for each log (its number and size)
    %     LOG_REQUEST_DATA  ->  a stream of LOG_DATA, 90 bytes each
    %     LOG_REQUEST_END   ->  the Cube goes back to logging normally
    %   (ArduPilot's AP_Logger_MAVLinkLogTransfer.cpp.)
    %
    %   Over the Kahuna's Wi-Fi the link to the Cube runs at 57600 baud, so
    %   this manages a few kB a second at best: a minute of the Cube's log
    %   (about 3 MB) can take ten minutes or more. USB is much faster.
    %
    %   Messages get lost on the way, so it keeps track of which 90-byte
    %   pieces have arrived, and asks again for any gaps.
    %
    %   Nothing here sends anything itself: list, download, cancel and tick
    %   hand back the requests to send, and CubeSource sends them. That way
    %   this object needs no link back to the connection.

    properties (SetAccess = private)
        State = "idle"   % "idle", "listing", "listed", "downloading", "done", "failed" or "cancelled"
        Entries = struct("id", {}, "size", {}, "timeUtc", {})   % the Cube's logs, from LOG_ENTRY
        Id = NaN         % the log being downloaded
        Size = 0         % its size in bytes
        File = ""        % where it's being saved
        Message = ""     % what went wrong, if State is "failed"
    end

    properties (Constant)
        Chunk = 90       % bytes in one LOG_DATA
        Silence = 1.5    % seconds without data before asking again
    end

    properties (Access = private)
        NumLogs = NaN
        LastHeard        % tic of the last LOG_ENTRY or LOG_DATA
        Started          % tic when the download started
        Data uint8
        Have logical     % one per 90-byte piece: arrived yet?
        Asked = [0 0]    % the piece range [first last] last asked for
        Tries = 0        % requests in a row that brought nothing
    end

    methods
        % ---- Called by the message callbacks (they only store data) --------

        function addEntry(obj, id, numLogs, timeUtc, size)
            obj.LastHeard = tic;
            obj.NumLogs = numLogs;
            if numLogs > 0 && ~ismember(id, [obj.Entries.id])
                obj.Entries(end+1) = struct("id", id, "size", size, "timeUtc", timeUtc);
            end
        end

        function addData(obj, id, ofs, count, data)
            if obj.State ~= "downloading" || id ~= obj.Id || count == 0
                return
            end
            obj.LastHeard = tic;
            obj.Tries = 0;
            k = floor(ofs / obj.Chunk) + 1;
            if k > numel(obj.Have) || mod(ofs, obj.Chunk) ~= 0
                return
            end
            last = min(ofs + count, obj.Size);
            obj.Data(ofs + 1:last) = data(1:last - ofs);
            obj.Have(k) = true;
        end

        % ---- Called by the window, through CubeSource ----------------------

        function requests = list(obj)
            % Ask for the list of logs on the Cube.
            obj.Entries = obj.Entries([]);
            obj.NumLogs = NaN;
            obj.State = "listing";
            obj.LastHeard = tic;
            requests = struct("kind", "list", "id", 0, "ofs", 0, "count", 0);
        end

        function entry = newest(obj)
            % The log with the highest number, which is the latest one.
            entry = [];
            if ~isempty(obj.Entries)
                [~, k] = max([obj.Entries.id]);
                entry = obj.Entries(k);
            end
        end

        function requests = download(obj, id, size, file)
            % Start downloading log number id (size bytes) into file.
            obj.Id = id;
            obj.Size = size;
            obj.File = string(file);
            obj.Message = "";
            obj.Data = zeros(1, size, "uint8");
            obj.Have = false(1, ceil(size / obj.Chunk));
            obj.State = "downloading";
            obj.Started = tic;
            obj.LastHeard = tic;
            obj.Tries = 0;
            requests = obj.askForNextGap();
        end

        function requests = cancel(obj)
            requests = obj.noRequests();
            if obj.State == "downloading" || obj.State == "listing"
                obj.State = "cancelled";
                requests = struct("kind", "end", "id", 0, "ofs", 0, "count", 0);
            end
        end

        function requests = tick(obj)
            % Call this often (the window does, 10 times a second). It
            % notices the end of the list, asks again for gaps, and saves
            % the file once every piece has arrived.
            requests = obj.noRequests();
            switch obj.State
                case "listing"
                    if numel(obj.Entries) >= obj.NumLogs || obj.NumLogs == 0
                        obj.State = "listed";
                    elseif toc(obj.LastHeard) > 3
                        % Some entries got lost: carry on with the ones we have.
                        obj.State = "listed";
                    end
                case "downloading"
                    if all(obj.Have)
                        requests = obj.finish();
                    elseif all(obj.Have(obj.Asked(1):obj.Asked(2))) || toc(obj.LastHeard) > obj.Silence
                        % That range has arrived (or gone quiet): ask for the next gap.
                        if toc(obj.LastHeard) > obj.Silence
                            obj.Tries = obj.Tries + 1;
                        end
                        if obj.Tries > 10
                            obj.State = "failed";
                            obj.Message = "The Cube stopped sending the log.";
                            requests = struct("kind", "end", "id", 0, "ofs", 0, "count", 0);
                        else
                            requests = obj.askForNextGap();
                        end
                    end
            end
        end

        function fraction = progress(obj)
            fraction = 0;
            if ~isempty(obj.Have)
                fraction = mean(obj.Have);
            end
        end

        function seconds = secondsLeft(obj)
            % A rough estimate from the speed so far (NaN at the start).
            seconds = NaN;
            got = obj.progress() * obj.Size;
            if obj.State == "downloading" && got > 0 && toc(obj.Started) > 3
                seconds = (obj.Size - got) / (got / toc(obj.Started));
            end
        end
    end

    methods (Access = private)
        function requests = askForNextGap(obj)
            % Ask for the first run of missing pieces, from its start to the
            % next piece we already have (or the end).
            first = find(~obj.Have, 1);
            next = find(obj.Have(first:end), 1);
            if isempty(next)
                last = numel(obj.Have);
            else
                last = first + next - 2;
            end
            obj.Asked = [first last];
            obj.LastHeard = tic;
            ofs = (first - 1) * obj.Chunk;
            count = min(last * obj.Chunk, obj.Size) - ofs;
            requests = struct("kind", "data", "id", obj.Id, "ofs", ofs, "count", count);
        end

        function requests = finish(obj)
            requests = struct("kind", "end", "id", 0, "ofs", 0, "count", 0);
            try
                f = fopen(obj.File, "w");
                if f < 0
                    error("CubeGUI:logDownload", "Couldn't open %s to write it.", obj.File)
                end
                closeIt = onCleanup(@() fclose(f));   % closes the file however this ends
                fwrite(f, obj.Data, "uint8");
                clear closeIt
                obj.State = "done";
            catch err
                obj.State = "failed";
                obj.Message = err.message;
            end
            obj.Data = zeros(1, 0, "uint8");   % don't hold on to megabytes
        end
    end

    methods (Static, Access = private)
        function requests = noRequests()
            requests = struct("kind", {}, "id", {}, "ofs", {}, "count", {});
        end
    end
end
