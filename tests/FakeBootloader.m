classdef FakeBootloader < handle
    %FAKEBOOTLOADER  A pretend Cube bootloader, for testing FirmwareUpload.
    %
    %   It stands in for the serialport: FirmwareUpload writes commands to it
    %   and reads its answers, as it would a real Cube's bootloader
    %   (ArduPilot's Tools/AP_Bootloader/bl_protocol.cpp). Its checksum is
    %   worked out bit by bit, separately from FirmwareUpload's, so the two
    %   can't share a mistake. Its flash is small, to keep that quick.

    properties
        BoardId = 1063
        FlashSize = 65536
        Flash = zeros(1, 0, "uint8")
        Rebooted = false
        DropNext = 0        % answers to throw away, to test lost replies
    end

    properties (Dependent)
        NumBytesAvailable
    end

    properties (Access = private)
        In = zeros(1, 0, "uint8")
        Out = zeros(1, 0, "uint8")
    end

    methods
        function n = get.NumBytesAvailable(obj)
            n = numel(obj.Out);
        end

        function flush(obj)
            obj.Out = zeros(1, 0, "uint8");
        end

        function bytes = read(obj, n, ~)
            bytes = double(obj.Out(1:n));
            obj.Out(1:n) = [];
        end

        function write(obj, bytes, ~)
            obj.In = [obj.In, uint8(bytes)];
            obj.process();
        end
    end

    methods (Access = private)
        function process(obj)
            % Answer every complete command waiting in In.
            while ~isempty(obj.In)
                switch obj.In(1)
                    case 0x21   % GET_SYNC, EOC
                        if numel(obj.In) < 2, return, end
                        obj.In(1:2) = [];
                        obj.answer([]);
                    case 0x22   % GET_DEVICE, arg, EOC
                        if numel(obj.In) < 3, return, end
                        values = [5, obj.BoardId, 0, obj.FlashSize];   % BL_REV, BOARD_ID, BOARD_REV, FLASH_SIZE
                        obj.answer(typecast(uint32(values(obj.In(2))), "uint8"));
                        obj.In(1:3) = [];
                    case 0x23   % CHIP_ERASE, EOC
                        if numel(obj.In) < 2, return, end
                        obj.In(1:2) = [];
                        obj.Flash = zeros(1, 0, "uint8");
                        obj.answer([]);
                    case 0x27   % PROG_MULTI, length, data, EOC
                        if numel(obj.In) < 2 || numel(obj.In) < 3 + double(obj.In(2)), return, end
                        n = double(obj.In(2));
                        obj.Flash = [obj.Flash, obj.In(3:2 + n)];
                        obj.In(1:3 + n) = [];
                        obj.answer([]);
                    case 0x29   % GET_CRC, EOC
                        if numel(obj.In) < 2, return, end
                        obj.In(1:2) = [];
                        obj.answer(typecast(uint32(obj.crc()), "uint8"));
                    case 0x30   % REBOOT, EOC
                        if numel(obj.In) < 2, return, end
                        obj.In(1:2) = [];
                        obj.Rebooted = true;
                        obj.answer([]);
                    otherwise
                        obj.In(1) = [];
                        obj.Out = [obj.Out, uint8([0x12 0x13])];   % INSYNC, INVALID
                end
            end
        end

        function answer(obj, payload)
            if obj.DropNext > 0
                obj.DropNext = obj.DropNext - 1;
                return
            end
            obj.Out = [obj.Out, uint8(payload), uint8([0x12 0x10])];   % ..., INSYNC, OK
        end

        function state = crc(obj)
            % CRC-32 from 0, no final inversion, bit by bit, over the flash
            % padded with 0xFF to its full size.
            data = [obj.Flash, repmat(uint8(255), 1, obj.FlashSize - numel(obj.Flash))];
            state = uint32(0);
            for b = data
                state = bitxor(state, uint32(b));
                for bit = 1:8
                    if bitand(state, 1)
                        state = bitxor(bitshift(state, -1), uint32(0xEDB88320));
                    else
                        state = bitshift(state, -1);
                    end
                end
            end
            state = double(state);
        end
    end
end
