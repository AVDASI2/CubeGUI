function tests = testCore
%TESTCORE  Automated checks for CubeGUI's pieces that don't need a window.
%
%   Run with:  runtests("tests")
tests = functiontests(localfunctions);
end

function setupOnce(tc)
root = fullfile(fileparts(mfilename("fullpath")), "..");
addpath(fullfile(root, "engine"));
tc.TestData.root = root;
end

function teardown(tc)
% After every test: no timers may be left running.
verifyEmpty(tc, timerfindall, "A test left a timer running.")
delete(timerfindall)
end

% ---- loadConfig ---------------------------------------------------------------

function testShippedConfigLoads(tc)
config = loadConfig(fullfile(tc.TestData.root, "config", "cubegui.json"));
verifyEqual(tc, config.servos(1).output, 5)
verifyEqual(tc, numel(config.servos), 3)
verifyClass(tc, config.servos(1).mapping, "ServoMapping")
verifyClass(tc, config.connection.cubeAddress, "string")
end

function testConfigServosWithDifferentEntries(tc)
% One servo with a calibration table, the others without: still loads.
file = writeConfig(tc, @(c) addTable(c));
config = loadConfig(file);
verifyEqual(tc, config.servos(1).mapping.Type, "table")
verifyEqual(tc, config.servos(2).mapping.Type, "pwm")
end

function testConfigRejectsBadMapping(tc)
file = writeConfig(tc, @(c) setMapping(c, struct("type", "custom", "expression", "system('ls')")));
verifyError(tc, @() loadConfig(file), "CubeGUI:config")
end

function testConfigRejectsOldPwmEntries(tc)
% PWM limits now come from the Cube. An old settings file with them in
% gets a message saying so, rather than having them quietly ignored.
file = writeConfig(tc, @(c) setServo1(c, "maxPwm", 1900));
verifyError(tc, @() loadConfig(file), "CubeGUI:config")
end

function testLimitsProblem(tc)
verifyEqual(tc, DataSource.limitsProblem(1100, 1500, 1900), "")
verifyEqual(tc, DataSource.limitsProblem(1000, 1500, 2000), "")
verifyNotEqual(tc, DataSource.limitsProblem(900, 1500, 1900), "")    % below 1000
verifyNotEqual(tc, DataSource.limitsProblem(1100, 1500, 2100), "")   % above 2000
verifyNotEqual(tc, DataSource.limitsProblem(1100, 1950, 1900), "")   % trim outside
verifyNotEqual(tc, DataSource.limitsProblem(1100, NaN, 1900), "")    % not read yet
end

function testLimitsOutsideHardRangeRefused(tc)
src = SimulatedSource(Telemetry(30, 20));
verifyError(tc, @() src.setServoLimits(5, 900, 1900), "CubeGUI:limits")
verifyError(tc, @() src.setServoLimits(5, 1100, 2100), "CubeGUI:limits")
end

function testConfigRejectsMissingEntry(tc)
file = writeConfig(tc, @(c) rmfield(c, "rates"));
verifyError(tc, @() loadConfig(file), "CubeGUI:config")
end

function testConfigRejectsBrokenJson(tc)
file = fullfile(tempdir, "cubegui_broken.json");
writelines("{ ""connection"": ", file);
verifyError(tc, @() loadConfig(file), "CubeGUI:config")
end

% ---- Telemetry -----------------------------------------------------------------

function testTelemetryHeartbeat(tc)
tel = Telemetry(30, 20);
verifyEqual(tc, tel.secondsSinceHeartbeat(), Inf)
tel.addHeartbeat();
verifyLessThan(tc, tel.secondsSinceHeartbeat(), 1)
verifyEqual(tc, tel.HeartbeatCount, 1)
end

function testTelemetryClearsOnReboot(tc)
% The Cube's clock jumping backwards means it rebooted: drop old samples.
tel = Telemetry(30, 20);
tel.addPitch(100, 1);
tel.addPitch(100.05, 2);
tel.addPitch(0.5, 3);
[t, p] = tel.Pitch.data();
verifyEqual(tc, t, 0.5)
verifyEqual(tc, p(1), 3)
end

function testTelemetryOutputClockWraps(tc)
% SERVO_OUTPUT_RAW's microsecond clock wraps at 2^32; time must keep rising.
% The pitch clock (milliseconds, no wrap) says how many wraps there have been.
tel = Telemetry(30, 20);
tel.addPitch(4294.90, 1);
tel.addOutputsUsec(2^32 - 50000, ones(1, 16));
tel.addPitch(4294.98, 1);
tel.addOutputsUsec(0, ones(1, 16));
[t, ~] = tel.Outputs.data();
verifyEqual(tc, t(2) - t(1), 0.05, AbsTol=1e-9)
end

function testTelemetryRebootAfterLongUptimeIsNotAWrap(tc)
% A Cube up for 40 minutes, then rebooted: its clocks jump from 2400 s to
% 1 s. That's a reboot, not a wrap, so time must start again.
tel = Telemetry(30, 20);
tel.addPitch(2400, 1);
tel.addOutputsUsec(2400e6, ones(1, 16));
tel.addPitch(1, 2);
tel.addOutputsUsec(1e6, 2 * ones(1, 16));
[t, pwm] = tel.Outputs.data();
verifyEqual(tc, t, 1, AbsTol=1e-9)
verifyEqual(tc, pwm(1), 2)
end

function testTelemetryOutputClockAfterConnectingLate(tc)
% Connecting to a Cube that has been on for 75 minutes: its output clock
% has already wrapped once, so it must be lined up with the pitch clock.
tel = Telemetry(30, 20);
tel.addPitch(4528.0, 1);
tel.addOutputsUsec(round((4528.0 - 2^32 / 1e6) * 1e6), ones(1, 16));
[t, ~] = tel.Outputs.data();
verifyEqual(tc, t, 4528.0, AbsTol=1e-3)
end

function testTelemetrySkipsLateSamples(tc)
% Samples held up on the Wi-Fi arrive late and out of order. They're
% skipped, and they mustn't be mistaken for a reboot.
tel = Telemetry(30, 20);
tel.addPitch(200, 1);
tel.addPitch(200.05, 2);
tel.addPitch(195, 3);        % 5 s late
tel.addPitch(200.05, 4);     % a repeat
tel.addPitch(200.10, 5);
[t, p] = tel.Pitch.data();
verifyEqual(tc, t', [200 200.05 200.10])
verifyEqual(tc, p(:, 1)', [1 2 5])
verifyEqual(tc, tel.LateCount, 2)
verifyEqual(tc, tel.RebootCount, 0)
end

function testTelemetryRebootSeenLate(tc)
% A Cube that rebooted while CubeGUI couldn't hear it, and has been back
% for over a minute: its samples stay behind, so after 3 s it's a reboot.
tel = Telemetry(30, 20);
tel.addPitch(2000, 1);
tel.addPitch(100, 2);
verifyEqual(tc, tel.RebootCount, 0)
pause(3.2)
tel.addPitch(103.2, 3);
verifyEqual(tc, tel.RebootCount, 1)
[t, ~] = tel.Pitch.data();
verifyEqual(tc, t, 103.2)
end

function testTelemetryCountsReboots(tc)
tel = Telemetry(30, 20);
tel.setVersion(struct("firmware", "4.6.2"));
tel.addPitch(100, 1);
tel.addOutputsUsec(100e6, ones(1, 16));
tel.addPitch(0.5, 2);                     % rebooted
tel.addOutputsUsec(0.5e6, ones(1, 16));
verifyEqual(tc, tel.RebootCount, 1)
verifyEmpty(tc, tel.Version, "After a reboot the version should be asked for again.")
[t, ~] = tel.Outputs.data();
verifyEqual(tc, t, 0.5)
end

function testSafetyFromSysStatus(tc)
% ArduPilot sets SYS_STATUS's "motor outputs" bit (32768) while safety is off.
tel = Telemetry(30, 20);
verifyTrue(tc, isnan(tel.SafetyOn))
tel.addSysStatus(32768 + 1 + 2);
verifyEqual(tc, tel.SafetyOn, false)
tel.addSysStatus(1 + 2);
verifyEqual(tc, tel.SafetyOn, true)
end

function testSetupParameterList(tc)
servos = struct("name", {"Elevator"; "Rudder"}, "output", {5; 6});
params = setupParameters(servos, ["SERVO8_FUNCTION", "THR_FAILSAFE"]);
names = [params.name];
verifyTrue(tc, all(ismember(["THR_FAILSAFE", "SERVO5_FUNCTION", "SERVO6_MAX", ...
    "BRD_SAFETY_MASK", "SERVO8_FUNCTION"], names)))
verifyEqual(tc, sum(names == "THR_FAILSAFE"), 1, "An extra that's already listed isn't repeated.")
verifyTrue(tc, params(names == "SERIAL1_BAUD").readOnly)
end

% ---- SimulatedSource -------------------------------------------------------------

function testSimulatedSourceRuns(tc)
tel = Telemetry(30, 20);
src = SimulatedSource(tel);
src.setServoLimits(5, 1100, 1900);
src.connect();
cleanup = onCleanup(@() delete(src));
pause(1.5)
verifyGreaterThanOrEqual(tc, tel.HeartbeatCount, 1)
verifyGreaterThan(tc, tel.Pitch.Count, 15)
verifyLessThan(tc, tel.secondsSinceHeartbeat(), 2)
end

function testServoCommandsAreClamped(tc)
tel = Telemetry(30, 20);
src = SimulatedSource(tel);
src.setServoLimits(5, 1100, 1900);
src.connect();
cleanup = onCleanup(@() delete(src));
verifyEqual(tc, src.setServo(5, 2500), 1900)
verifyEqual(tc, src.setServo(5, 200), 1100)
verifyEqual(tc, src.setServo(5, 1612.4), 1612)
pause(0.2)
[~, pwm] = tel.Outputs.data();
verifyEqual(tc, pwm(end, 5), 1612)
end

function testUnconfiguredOutputRefused(tc)
src = SimulatedSource(Telemetry(30, 20));
src.connect();
cleanup = onCleanup(@() delete(src));
verifyError(tc, @() src.setServo(3, 1500), "CubeGUI:noLimits")
end

function testNothingSentWhenDisconnected(tc)
src = SimulatedSource(Telemetry(30, 20));
src.setServoLimits(5, 1100, 1900);
verifyError(tc, @() src.setServo(5, 1500), "CubeGUI:notConnected")
end

function testPortInUseMessages(tc)
% The macOS text is real (seen 2026-10-21); the Windows ones are from
% Microsoft's documentation, including a German Windows by its number.
mac = "UDP open failed because bind: Address already in use [system:48 at /x/y.hpp:161:33]";
windows = "UDP open failed because bind: Only one usage of each socket address " + ...
    "(protocol/network address/port) is normally permitted [system:10048 at x]";
german = "UDP open failed because bind: Normalerweise darf jede Socketadresse " + ...
    "nur jeweils einmal verwendet werden [system:10048 at x]";
other = "UDP open failed because bind: Permission denied [system:13 at x]";
for text = [mac, windows, german]
    verifyTrue(tc, CubeSource.isPortInUse(MException("a:b", "%s", text)), text)
end
verifyFalse(tc, CubeSource.isPortInUse(MException("a:b", "%s", other)))
end

% ---- Helpers ------------------------------------------------------------------------

function file = writeConfig(tc, change)
% Write a changed copy of the shipped settings to a temporary file.
config = jsondecode(fileread(fullfile(tc.TestData.root, "config", "cubegui.json")));
config = change(config);
file = fullfile(tempdir, "cubegui_test.json");
writelines(jsonencode(config), file);
end

function c = setServo1(c, field, value)
c.servos(1).(field) = value;
end

function c = addTable(c)
c = jsondecode(jsonencode(c));   % plain copy
s = num2cell(c.servos);
s{1}.units = "deg";
s{1}.mapping = struct("type", "table", "points", [-20 1100; 0 1500; 20 1900]);
c.servos = s;
end

function c = setMapping(c, mapping)
s = num2cell(c.servos);
s{1}.units = "deg";
s{1}.range = [-10 10];
s{1}.mapping = mapping;
c.servos = s;
end

% ---- calibrationTable ------------------------------------------------------------

function testCalibrationTable(tc)
% Up and down sweeps of a mechanism with 2 degrees of hysteresis.
pwm = [1100 1300 1500 1700 1900 1700 1500 1300 1100];
up = [true true true true true false false false false];
angle = [-20 -9 1 11 20 12 3 -7 -20];
t = calibrationTable(pwm, angle, up);
verifyEqual(tc, t.points(:, 2)', [1100 1300 1500 1700 1900])
verifyEqual(tc, t.points(:, 1)', [-20 -8 2 11.5 20])
verifyEqual(tc, t.hysteresis, 2)
verifyTrue(tc, contains(t.settings, '"type": "table"'))
% The settings it gives load as a real mapping.
m = ServoMapping(struct("minPwm", 1100, "trimPwm", 1500, "maxPwm", 1900, "units", "deg", ...
    "mapping", struct("type", "table", "points", t.points)));
verifyEqual(tc, m.toPwm(20), 1900)
end

function testCalibrationTableReversedMechanism(tc)
% Angle falling as PWM rises is fine: the mapping just goes down.
t = calibrationTable([1100 1500 1900], [15 0 -15], [true true true]);
verifyEqual(tc, t.points, [-15 1900; 0 1500; 15 1100])
verifyTrue(tc, isnan(t.hysteresis), "Nothing measured both ways.")
end

function testCalibrationTableRejectsMuddle(tc)
verifyError(tc, @() calibrationTable([1100 1300 1500], [0 5 3], [true true true]), "CubeGUI:calibration")
end

function testLogDownloadFillsGaps(tc)
% LogDownload asks again for pieces that got lost, and saves the file.
logs = LogDownload();
logs.list();
logs.addEntry(3, 2, 0, 1000);
logs.addEntry(4, 2, 0, 250);   % 250 bytes: pieces of 90, 90 and 70
logs.tick();
verifyEqual(tc, logs.State, "listed")
verifyEqual(tc, logs.newest().id, 4)
file = string(tempname) + ".BIN";
data = uint8(mod(0:249, 256));
r = logs.download(4, 250, file);
verifyEqual(tc, [r.ofs r.count], [0 250], "First, ask for the whole log.")
logs.addData(4, 0, 90, data(1:90));
logs.addData(4, 180, 70, [data(181:250), zeros(1, 20, "uint8")]);   % the middle piece is lost
pause(1.6)                                   % silence: ask again for the gap
r = logs.tick();
verifyEqual(tc, [r.kind r.ofs r.count], ["data" "90" "90"])
logs.addData(4, 90, 90, data(91:180));
r = logs.tick();
verifyEqual(tc, logs.State, "done")
verifyEqual(tc, r.kind, "end", "Tell the Cube the download is over.")
f = fopen(file); saved = fread(f, Inf, "*uint8")'; fclose(f);
verifyEqual(tc, saved, data)
delete(file)
end

function testFtpUploadSteps(tc)
% FtpUpload goes reset, create, write..., close, and sends a lost request
% again with the same sequence number.
up = FtpUpload();
data = uint8(mod(1:500, 256));
p = up.start("/APM/scripts/cubegui.lua", data);
verifyEqual(tc, p{1}(4), uint8(2), "First, reset any open sessions.")
up.addReply(ftpAck(p{1}, 0));
p = up.tick();
verifyEqual(tc, p{1}(4), uint8(6), "Then create the file.")
verifyEqual(tc, char(p{1}(13:12 + p{1}(5))), '/APM/scripts/cubegui.lua')
up.addReply(ftpAck(p{1}, 5));               % the Cube gives session 5
written = zeros(1, 0, "uint8");
p = up.tick();
lost = true;
while up.Step == "write"
    verifyEqual(tc, p{1}(3), uint8(5), "Writes use the Cube's session.")
    if lost
        lost = false;                       % the first write's answer goes missing
        pause(1.1)
        again = up.tick();
        verifyEqual(tc, again{1}, p{1}, "Sent again, unchanged.")
    end
    offset = double(typecast(p{1}(9:12), "uint32"));
    verifyEqual(tc, offset, numel(written))
    written = [written, p{1}(13:12 + p{1}(5))]; %#ok<AGROW>
    up.addReply(ftpAck(p{1}, 5));
    p = up.tick();
end
verifyEqual(tc, written, data)
verifyEqual(tc, p{1}(4), uint8(1), "Last, close the session.")
up.addReply(ftpAck(p{1}, 5));
up.tick();
verifyEqual(tc, up.State, "done")
end

function testFtpUploadNak(tc)
up = FtpUpload();
p = up.start("/APM/scripts/cubegui.lua", uint8(1:10));
up.addReply(ftpAck(p{1}, 0));
p = up.tick();
r = ftpAck(p{1}, 0);
r(4) = 129;   % NAK
r(13) = 10;   % file not found: no APM/scripts folder
up.addReply(r);
up.tick();
verifyEqual(tc, up.State, "failed")
verifyTrue(tc, contains(up.Message, "wasn't found"), up.Message)
end

function r = ftpAck(request, session)
% The Cube's ACK to an FTP request: its sequence number plus one.
r = zeros(1, 251, "uint8");
r(1:2) = typecast(typecast(request(1:2), "uint16") + 1, "uint8");
r(3) = session;
r(4) = 128;
end

function testFirmwareCrc(tc)
% The bootloader's checksum: CRC-32 from 0 with no final inversion, as
% ArduPilot's uploader.py computes it (values checked against its table).
verifyEqual(tc, FirmwareUpload.crc32(uint8('123456789'), 9), hex2dec("2DFD2D88"))
verifyEqual(tc, FirmwareUpload.crc32(uint8('123456789'), 16), hex2dec("801A57E1"), ...
    "Padded with 0xFF, as erased flash reads.")
end

function testFirmwareAbin(tc)
% An .abin file is header lines, "--", then the firmware image.
file = string(tempname) + ".abin";
image = uint8([0 10 45 45 10 255 1 2]);   % contains "\n--\n" itself, to check only the first counts
f = fopen(file, "w");
fwrite(f, sprintf("git version: abc\nMD5: 123\n--\n"));
fwrite(f, image, "uint8");
fclose(f);
fw = FirmwareUpload.readAbin(file);
verifyEqual(tc, fw.image, image)
verifyEqual(tc, fw.headers', ["git version: abc", "MD5: 123"])
delete(file)
verifyEqual(tc, FirmwareUpload.boardName(1063), "CubeOrangePlus")
verifyEqual(tc, FirmwareUpload.boardName(9), "")
end

function testFirmwareFlash(tc)
% Identify, erase, program, check and reboot, against a pretend bootloader.
bl = FakeBootloader();
up = FirmwareUpload(bl);
info = up.identify();
verifyEqual(tc, [info.bootloaderRev info.boardId info.flashSize], [5 1063 65536])
verifyEqual(tc, info.boardName, "CubeOrangePlus")
image = uint8(randi([0 255], 1, 10001));   % not a multiple of 4
up.flash(image, @(~, ~) []);
verifyEqual(tc, bl.Flash(1:10001), image)
verifyEqual(tc, bl.Flash(10002:end), uint8([255 255 255]), "Padded to a whole word with 0xFF.")
verifyTrue(tc, bl.Rebooted)
end

function testFirmwareTooBig(tc)
bl = FakeBootloader();
up = FirmwareUpload(bl);
up.identify();
verifyError(tc, @() up.flash(zeros(1, 70000, "uint8"), @(~, ~) []), "CubeGUI:firmware")
verifyEmpty(tc, bl.Flash, "Nothing written when it doesn't fit.")
end

function testFirmwareLostAnswer(tc)
% If the bootloader's answer goes missing, the upload stops with a message
% rather than carrying on out of step.
bl = FakeBootloader();
up = FirmwareUpload(bl);
up.identify();
bl.DropNext = 1;   % the erase's answer is lost
up.EraseSeconds = 1;   % don't wait the full 20 s
verifyError(tc, @() up.flash(uint8(1:100), @(~, ~) []), "CubeGUI:firmware")
end

function testFindMavlinkOnMissingPort(tc)
% Labelling the USB ports: a port that can't be opened is "in use", and
% before R2026b (no MAVLink over serial) every label is left blank.
% Hearing a real heartbeat is checked by tools/sitl/test_usb_connection.m.
found = CubeSource.findMavlink(["/dev/no-such-port" "COM999"], 0);
if isMATLABReleaseOlderThan("R2026b")
    verifyEqual(tc, found, ["" ""])
else
    verifyEqual(tc, found, ["in use" "in use"])
end
end

function testResetToFreshInSimulation(tc)
% FORMAT_VERSION 0, then a reboot: every parameter back to its default.
tel = Telemetry(30, 20);
src = SimulatedSource(tel);
src.connect();
cleanup = onCleanup(@() delete(src));
src.setParam("SERVO5_MAX", 1800);
src.setParam("SCR_ENABLE", 1);
src.reboot();
src.requestParams("SERVO5_MAX");
verifyEqual(tc, tel.param("SERVO5_MAX"), 1800, "An ordinary reboot keeps the settings.")
src.setParam("FORMAT_VERSION", 0);
src.reboot();
src.requestParams(["SERVO5_MAX", "SCR_ENABLE", "FORMAT_VERSION"]);
verifyEqual(tc, [tel.param("SERVO5_MAX") tel.param("SCR_ENABLE") tel.param("FORMAT_VERSION")], [1900 0 13])
end
