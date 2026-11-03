classdef FirmwareUpload < handle
    %FIRMWAREUPLOAD  Flashes ArduPilot firmware onto a Cube over USB.
    %
    %   Part of CubeGUI's engine (from level 1). It does what Mission Planner's
    %   "Install Firmware" does, so Mac users don't need Mission Planner.
    %
    %   It talks to the Cube's bootloader, not to ArduPilot itself: the
    %   bootloader runs for a moment after power-up, or stays running if
    %   ArduPilot was asked to reboot into it (CubeSource.reboot(true)). Its
    %   protocol is ArduPilot's Tools/scripts/uploader.py, ported here:
    %
    %     GET_SYNC          are you there? (each answer ends INSYNC, OK)
    %     GET_DEVICE        the bootloader's version, the board's ID, the flash size
    %     CHIP_ERASE        erase the old firmware (takes up to 20 s)
    %     PROG_MULTI        write 252 bytes at a time
    %     GET_CRC           a checksum of the flash, to compare with ours
    %     REBOOT            start the new firmware
    %
    %   The firmware comes as an .abin file: a few header lines, "--", then
    %   the firmware image itself. ArduPilot publishes one for each board,
    %   e.g. https://firmware.ardupilot.org/Plane/stable/CubeOrangePlus/arduplane.abin
    %   (The .apj file Mission Planner uses holds the same image, compressed;
    %   MATLAB has no built-in way to uncompress it.)
    %
    %   A failed upload can't break a Cube: the bootloader isn't touched, so
    %   uploading again puts it right.
    %
    %   up = FirmwareUpload(port);         % e.g. "COM5" or "/dev/cu.usbmodem1101"
    %   info = up.identify();              % .boardId, .boardName, .flashSize, ...
    %   up.flash(image, @(fraction, text) ...)   % progress, 0 to 1 (NaN: busy, no fraction)
    %   delete(up)                         % closes the port

    properties (SetAccess = private)
        Port      % the serial port's name
    end

    properties
        EraseSeconds = 90   % how long an erase may take (a Cube Orange+ took about 30 s)
    end

    properties (Constant)
        % Board IDs (ArduPilot's Tools/AP_Bootloader/board_types.txt) for the
        % kits' Cubes, and the folder name on firmware.ardupilot.org.
        Boards = struct("id", {140, 1063}, "name", {"CubeOrange", "CubeOrangePlus"})
        ChunkSize = 252   % bytes per PROG_MULTI: at most 255, and a multiple of 4
    end

    properties (Constant, Access = private)
        INSYNC = 0x12; EOC = 0x20; OK = 0x10; FAILED = 0x11; INVALID = 0x13
        GET_SYNC = 0x21; GET_DEVICE = 0x22; CHIP_ERASE = 0x23; PROG_MULTI = 0x27
        GET_CRC = 0x29; REBOOT = 0x30
        INFO_BL_REV = 1; INFO_BOARD_ID = 2; INFO_BOARD_REV = 3; INFO_FLASH_SIZE = 4
    end

    properties (Access = private)
        Serial            % the serialport
        BootloaderRev = NaN
        FlashSize = NaN
    end

    methods
        function obj = FirmwareUpload(port)
            % port is the serial port's name. (The tests pass a stand-in
            % object instead, with serialport's write, read, flush and
            % NumBytesAvailable: tests/FakeBootloader.m.)
            if isstring(port) || ischar(port)
                obj.Port = string(port);
                % USB ignores the speed, but the bootloader also listens on the
                % Cube's serial ports at 115200 (AP_Bootloader/support.cpp).
                % After a sync and the identify questions, the bootloader stops
                % its 5 s timer and waits as long as needed (bl_protocol.cpp).
                obj.Serial = serialport(obj.Port, 115200, Timeout=1);
            else
                obj.Port = "(test)";
                obj.Serial = port;
            end
        end

        function delete(obj)
            obj.Serial = [];   % closes the port
        end

        function info = identify(obj, attempts)
            % Get in step with the bootloader and ask what it is. attempts
            % (default 5) is how many times to try to get in step.
            if nargin < 2
                attempts = 5;
            end
            obj.sync(attempts);
            obj.BootloaderRev = obj.getInfo(obj.INFO_BL_REV);
            if obj.BootloaderRev < 2 || obj.BootloaderRev > 5
                error("CubeGUI:firmware", "This bootloader's protocol (version %d) isn't one " + ...
                    "CubeGUI knows. Use Mission Planner for this Cube.", obj.BootloaderRev)
            end
            info.bootloaderRev = obj.BootloaderRev;
            info.boardId = obj.getInfo(obj.INFO_BOARD_ID);
            info.boardRev = obj.getInfo(obj.INFO_BOARD_REV);
            obj.FlashSize = obj.getInfo(obj.INFO_FLASH_SIZE);
            info.flashSize = obj.FlashSize;
            info.boardName = FirmwareUpload.boardName(info.boardId);
        end

        function flash(obj, image, progress)
            % Erase, program and check. progress(fraction, text) is called
            % as it goes. Call identify first.
            if isnan(obj.FlashSize)
                error("CubeGUI:firmware", "Call identify before flash.")
            end
            image = FirmwareUpload.padded(image);
            if numel(image) > obj.FlashSize
                error("CubeGUI:firmware", "This firmware (%d bytes) is too big for the " + ...
                    "Cube's flash (%d bytes). Is it for the right board?", numel(image), obj.FlashSize)
            end

            % Erase: the bootloader answers once it's done, which on a Cube
            % Orange+ took about 30 s. It can't say how far it has got, so
            % the progress is NaN ("busy") with the seconds so far.
            progress(NaN, "Erasing the old firmware. This takes up to a minute...");
            obj.send([obj.CHIP_ERASE obj.EOC]);
            obj.waitForSync(obj.EraseSeconds, @(seconds) progress(NaN, sprintf( ...
                "Erasing the old firmware (%d s). This takes up to a minute...", round(seconds))));

            % Program, 252 bytes at a time.
            chunks = ceil(numel(image) / obj.ChunkSize);
            for k = 1:chunks
                data = image((k - 1) * obj.ChunkSize + 1:min(k * obj.ChunkSize, end));
                obj.send([obj.PROG_MULTI numel(data) data obj.EOC]);
                obj.getSync();
                if mod(k, 64) == 0 || k == chunks
                    progress(0.05 + 0.9 * k / chunks, sprintf("Writing: %.0f %%", 100 * k / chunks));
                end
            end

            % Check: the bootloader's checksum of the whole flash against ours,
            % with the unused part counted as erased (0xFF).
            progress(0.96, "Checking...");
            obj.send([obj.GET_CRC obj.EOC]);
            theirs = obj.receiveInt();
            obj.getSync();
            ours = FirmwareUpload.crc32(image, obj.FlashSize);
            if theirs ~= ours
                error("CubeGUI:firmware", "The firmware didn't check out on the Cube " + ...
                    "(checksum %08X, expected %08X). Try again.", theirs, ours)
            end

            % Start the new firmware. From protocol 3 the bootloader answers
            % first, but the Cube may restart before the answer arrives.
            progress(1, "Done. Restarting the Cube...");
            obj.send([obj.REBOOT obj.EOC]);
            try
                obj.getSync();
            catch
            end
        end
    end

    methods
        function restart(obj)
            % Leave the bootloader without flashing: start the firmware already there.
            obj.send([obj.REBOOT obj.EOC]);
        end
    end

    methods (Static)
        function fw = readAbin(file)
            % Read an .abin firmware file: header lines, "--", then the image.
            f = fopen(file, "r");
            if f < 0
                error("CubeGUI:firmware", "Couldn't open %s.", file)
            end
            bytes = fread(f, Inf, "*uint8")';
            fclose(f);
            marker = strfind(char(bytes), sprintf("\n--\n"));   % the end of the headers
            if isempty(marker)
                error("CubeGUI:firmware", "%s isn't an .abin firmware file (no ""--"" line).", file)
            end
            fw.headers = splitlines(string(char(bytes(1:marker(1)))));
            fw.headers = fw.headers(fw.headers ~= "");
            fw.image = bytes(marker(1) + 4:end);
            if isempty(fw.image)
                error("CubeGUI:firmware", "%s has no firmware in it.", file)
            end
        end

        function name = boardName(id)
            % The board's name on firmware.ardupilot.org, or "" if it isn't a kit's Cube.
            k = find([FirmwareUpload.Boards.id] == id, 1);
            name = "";
            if ~isempty(k)
                name = FirmwareUpload.Boards(k).name;
            end
        end

        function state = crc32(data, paddedTo)
            % The bootloader's checksum (AP_Math's crc_crc32: CRC-32 with a
            % starting value of 0 and no final inversion), of data followed
            % by 0xFF up to paddedTo bytes, as the erased flash reads.
            persistent table
            if isempty(table)
                table = zeros(1, 256, "uint32");
                for n = 0:255
                    c = uint32(n);
                    for bit = 1:8
                        if bitand(c, 1)
                            c = bitxor(bitshift(c, -1), uint32(0xEDB88320));
                        else
                            c = bitshift(c, -1);
                        end
                    end
                    table(n + 1) = c;
                end
            end
            state = uint32(0);
            for b = data
                state = bitxor(table(double(bitand(bitxor(state, uint32(b)), 255)) + 1), bitshift(state, -8));
            end
            for k = 1:max(0, paddedTo - numel(data))
                state = bitxor(table(double(bitand(bitxor(state, uint32(255)), 255)) + 1), bitshift(state, -8));
            end
            state = double(state);
        end
    end

    methods (Static, Access = private)
        function image = padded(image)
            % The bootloader writes whole 4-byte words: pad with 0xFF, like erased flash.
            image = [uint8(image(:)'), repmat(uint8(255), 1, mod(-numel(image), 4))];
        end
    end

    methods (Access = private)
        function send(obj, bytes)
            write(obj.Serial, uint8(bytes), "uint8");
        end

        function bytes = receive(obj, n)
            % Wait up to a second for n bytes, then read them.
            started = tic;
            while obj.Serial.NumBytesAvailable < n
                if toc(started) > 1
                    error("CubeGUI:firmware", "The Cube's bootloader stopped answering.")
                end
                pause(0.001)
            end
            bytes = read(obj.Serial, n, "uint8");
        end

        function value = receiveInt(obj)
            value = double(typecast(uint8(obj.receive(4)), "uint32"));   % little-endian
        end

        function getSync(obj)
            % Every answer ends INSYNC, then OK (or a reason it failed).
            reply = obj.receive(2);
            if reply(1) ~= obj.INSYNC
                error("CubeGUI:firmware", "The bootloader's answer didn't make sense (0x%02X).", reply(1))
            elseif reply(2) == obj.INVALID
                error("CubeGUI:firmware", "The bootloader refused the request as invalid.")
            elseif reply(2) == obj.FAILED
                error("CubeGUI:firmware", "The bootloader says the operation failed.")
            elseif reply(2) ~= obj.OK
                error("CubeGUI:firmware", "The bootloader's answer didn't make sense (0x%02X).", reply(2))
            end
        end

        function sync(obj, attempts)
            % Throw away anything left over, then ask until it answers.
            for attempt = 1:attempts
                flush(obj.Serial);
                obj.send([obj.GET_SYNC obj.EOC]);
                try
                    obj.getSync();
                    return
                catch
                    pause(0.2)
                end
            end
            error("CubeGUI:firmware", "No bootloader answered on %s.", obj.Port)
        end

        function value = getInfo(obj, what)
            obj.send([obj.GET_DEVICE what obj.EOC]);
            value = obj.receiveInt();
            obj.getSync();
        end

        function waitForSync(obj, seconds, waiting)
            % After an erase: keep listening until the answer comes, or give
            % up. waiting(secondsSoFar) is called about once a second.
            started = tic;
            lastCall = 0;
            while toc(started) < seconds
                if obj.Serial.NumBytesAvailable >= 2
                    obj.getSync();
                    return
                end
                if toc(started) - lastCall >= 1
                    lastCall = toc(started);
                    waiting(lastCall);
                end
                pause(0.1)
            end
            error("CubeGUI:firmware", "The Cube took too long to erase its firmware. Try again.")
        end
    end
end
