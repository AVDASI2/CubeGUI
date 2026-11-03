classdef FtpUpload < handle
    %FTPUPLOAD  Copies a file onto the Cube's SD card over MAVLink (MAVFTP).
    %
    %   Part of CubeGUI's engine: it's how the Setup tab installs
    %   lua/cubegui.lua without Mission Planner. CubeSource owns one.
    %
    %   This is MAVLink's file transfer protocol, the one behind Mission
    %   Planner's MAVFtp window (https://mavlink.io/en/services/ftp.html, and
    %   ArduPilot's GCS_FTP.cpp). Each step is one FILE_TRANSFER_PROTOCOL
    %   message, and the Cube answers each with an ACK or a NAK:
    %     ResetSessions        close anything left open from before
    %     CreateFile <path>    open the file, emptying it if it's there already
    %     WriteFile            239 bytes at a time, at the given offset
    %     TerminateSession     close the file
    %   UAV Toolbox has this built in from R2026b (ftpMicroservice). CubeGUI
    %   does it by hand so it also works on R2026a.
    %
    %   A message lost on the Wi-Fi is sent again with the same sequence
    %   number; ArduPilot then repeats its last answer rather than doing the
    %   step twice. Like LogDownload, nothing here sends anything itself:
    %   start and tick hand back the payloads, and CubeSource sends them.

    properties (SetAccess = private)
        State = "idle"   % "idle", "uploading", "done" or "failed"
        Step = ""        % "reset", "create", "write" or "close"
        Path = ""        % where on the Cube, e.g. "/APM/scripts/cubegui.lua"
        Size = 0
        Message = ""     % what went wrong, if State is "failed"
    end

    properties (Constant)
        ChunkSize = 239  % data bytes in one message
        Timeout = 1      % seconds to wait for an answer before sending again
        MaxTries = 6
        % Opcodes (MAV_FTP_OPCODE)
        OpTerminate = 1
        OpReset = 2
        OpCreate = 6
        OpWrite = 7
        OpAck = 128
        OpNak = 129
    end

    properties (Access = private)
        Data uint8
        Offset = 0       % bytes written so far
        Session = 0
        Seq = 0          % sequence number of the request waiting for an answer
        Pending          % that request's payload, to send again if need be
        SentAt           % tic when it was last sent
        Tries = 0
        Reply = []       % the newest answer that matches Seq, from addReply
    end

    methods
        function payloads = start(obj, path, data)
            % Begin copying data (uint8) to path on the Cube.
            obj.Path = string(path);
            obj.Data = uint8(data(:)');
            obj.Size = numel(obj.Data);
            obj.Offset = 0;
            obj.Message = "";
            obj.State = "uploading";
            obj.Seq = 0;
            payloads = obj.request("reset", obj.OpReset, 0, uint8([]));
        end

        function addReply(obj, payload)
            % Called by the FILE_TRANSFER_PROTOCOL callback. Keeps only the
            % answer to the request we're waiting for.
            if obj.State ~= "uploading" || numel(payload) < 12
                return
            end
            seq = double(payload(1)) + 256 * double(payload(2));
            if seq == mod(obj.Seq + 1, 65536)
                obj.Reply = uint8(payload(:)');
            end
        end

        function payloads = tick(obj)
            % Call this often (the window does, 10 times a second).
            payloads = {};
            if obj.State ~= "uploading"
                return
            end
            if isempty(obj.Reply)
                if toc(obj.SentAt) > obj.Timeout
                    if obj.Tries >= obj.MaxTries
                        obj.fail("The Cube stopped answering.");
                    else
                        obj.Tries = obj.Tries + 1;
                        obj.SentAt = tic;
                        payloads = {obj.Pending};   % the same request, the same number
                    end
                end
                return
            end
            r = obj.Reply;
            obj.Reply = [];
            if r(4) == obj.OpNak
                obj.fail(FtpUpload.nakText(r, obj.Step));
                return
            end
            switch obj.Step
                case "reset"
                    name = uint8(char(obj.Path));
                    payloads = obj.request("create", obj.OpCreate, 0, name);
                case "create"
                    obj.Session = r(3);
                    payloads = obj.nextWrite();
                case "write"
                    obj.Offset = min(obj.Offset + obj.ChunkSize, obj.Size);
                    payloads = obj.nextWrite();
                case "close"
                    obj.State = "done";
            end
        end

        function fraction = progress(obj)
            fraction = 0;
            if obj.Size > 0
                fraction = obj.Offset / obj.Size;
            end
        end
    end

    methods (Access = private)
        function payloads = nextWrite(obj)
            if obj.Offset >= obj.Size
                payloads = obj.request("close", obj.OpTerminate, 0, uint8([]));
            else
                last = min(obj.Offset + obj.ChunkSize, obj.Size);
                payloads = obj.request("write", obj.OpWrite, obj.Offset, obj.Data(obj.Offset + 1:last));
            end
        end

        function payloads = request(obj, step, opcode, offset, data)
            % Build one FTP payload (251 bytes): the 12-byte header, then data.
            obj.Step = step;
            obj.Seq = mod(obj.Seq + 2, 65536);   % the Cube's answer takes Seq + 1
            p = zeros(1, 251, "uint8");
            p(1:2) = typecast(uint16(obj.Seq), "uint8");      % little-endian, as MAVLink is
            p(3) = obj.Session;
            p(4) = opcode;
            p(5) = numel(data);
            p(9:12) = typecast(uint32(offset), "uint8");
            p(13:12 + numel(data)) = data;
            obj.Pending = p;
            obj.SentAt = tic;
            obj.Tries = 0;
            obj.Reply = [];
            payloads = {p};
        end

        function fail(obj, text)
            obj.State = "failed";
            obj.Message = text;
        end
    end

    methods (Static, Access = private)
        function text = nakText(r, step)
            % The NAK's first data byte says why (MAV_FTP_ERR).
            reasons = ["it failed", "it failed (an error on the Cube's SD card)", ...
                "the message was the wrong size", "the session wasn't open", ...
                "no sessions were free", "it reached the end of the file", ...
                "the Cube didn't know the command", "the file is there already", ...
                "the file is protected", "the folder or file wasn't found"];
            code = double(r(13));
            reason = "of error " + code;
            if code >= 1 && code <= numel(reasons)
                reason = reasons(code);
            end
            text = sprintf("The Cube refused the %s step, because %s.", step, reason);
        end
    end
end
