function tests = testCsvLogger
%TESTCSVLOGGER  Checks the CSV log: its columns, its rate, and its timestamps.
%
%   Run with:  runtests("tests")
tests = functiontests(localfunctions);
end

function setupOnce(~)
addpath(fullfile(fileparts(mfilename("fullpath")), "..", "engine"));
end

function setup(tc)
tc.TestData.folder = string(tempname);
servos = struct("name", {"Elevator"; "Rudder"}, "output", {5; 6});
tc.TestData.tel = Telemetry(30, 20);
tc.TestData.logger = CsvLogger(tc.TestData.tel, servos, tc.TestData.folder);
end

function teardown(tc)
tc.TestData.logger.stop();
verifyEmpty(tc, timerfindall, "A test left a timer running.")
delete(timerfindall)
end

function testHeaderAndRows(tc)
tel = tc.TestData.tel;
logger = tc.TestData.logger;
logger.start();
for k = 1:5
    tel.addOutputsUsec(k * 50000, 1500 * ones(1, 16));
    tel.addPitch(k * 0.05, k);
end
logger.stop();
log = readtable(logger.File, TextType="string");
verifyEqual(tc, string(log.Properties.VariableNames), ...
    ["utc_time", "laptop_posix_s", "cube_time_ms", "pitch_deg", "pitch_rate_dps", ...
     "elevator_cmd_us", "elevator_out_us", "rudder_cmd_us", "rudder_out_us", "marker"])
verifyEqual(tc, height(log), 5)
verifyEqual(tc, log.cube_time_ms', 50:50:250)
verifyEqual(tc, log.pitch_deg', 1:5)
verifyEqual(tc, log.elevator_out_us', 1500 * ones(1, 5))
verifyTrue(tc, all(isnan(log.elevator_cmd_us)), "Nothing was sent, so commanded should be empty.")
end

function testEachSampleWrittenOnce(tc)
% Samples arriving across several writes must each appear exactly once.
tel = tc.TestData.tel;
logger = tc.TestData.logger;
logger.start();
for k = 1:10
    tel.addPitch(k * 0.05, k);
    if mod(k, 3) == 0
        logger.writeNew();
    end
end
logger.stop();
log = readtable(logger.File);
verifyEqual(tc, log.pitch_deg', 1:10)
end

function testCommandsLineUpWithSamples(tc)
% Cube time runs at the same rate as the laptop's, as on a real Cube.
tel = tc.TestData.tel;
logger = tc.TestData.logger;
logger.start();
tel.addPitch(0.05, 0);
tel.addCommand(5, 1700);
pause(0.05)
tel.addPitch(0.10, 0);
tel.addCommand(6, 1200);
pause(0.05)
tel.addPitch(0.15, 0);
logger.stop();
log = readtable(logger.File);
verifyTrue(tc, isnan(log.elevator_cmd_us(1)))
verifyEqual(tc, log.elevator_cmd_us(2:3)', [1700 1700])
verifyTrue(tc, isnan(log.rudder_cmd_us(2)))
verifyEqual(tc, log.rudder_cmd_us(3), 1200)
end

function testCommandsPlacedByCubeTimeWhenSamplesArriveLate(tc)
% Samples from before a command, arriving after it (held up on the Wi-Fi),
% must still show the old command: they happened before it was sent.
tel = tc.TestData.tel;
logger = tc.TestData.logger;
logger.start();
tel.addPitch(100.00, 1);      % arrives on time: sets the clock difference
pause(0.5)
tel.addCommand(5, 1700);      % sent at about Cube time 100.5
tel.addPitch(100.20, 2);      % these two were held up on the way
tel.addPitch(100.40, 3);
pause(0.2)
tel.addPitch(100.70, 4);      % after the command
logger.stop();
log = readtable(logger.File);
verifyEqual(tc, log.pitch_deg', [1 2 3 4])
verifyTrue(tc, all(isnan(log.elevator_cmd_us(1:3))), "Before the command was sent.")
verifyEqual(tc, log.elevator_cmd_us(4), 1700)
end

function testUtcTimeMatchesLaptopClock(tc)
tel = tc.TestData.tel;
logger = tc.TestData.logger;
logger.start();
tel.addPitch(0.05, 0);
logger.stop();
log = readtable(logger.File, TextType="string");
logged = datetime(log.utc_time(1), InputFormat="yyyy-MM-dd'T'HH:mm:ss.SSS'Z'", TimeZone="UTC");
verifyLessThan(tc, abs(seconds(datetime("now", TimeZone="UTC") - logged)), 5)
verifyEqual(tc, posixtime(logged), log.laptop_posix_s(1), AbsTol=0.002)
end

function testCubeRebootStartsCountingAgain(tc)
tel = tc.TestData.tel;
logger = tc.TestData.logger;
logger.start();
tel.addPitch(100, 1);
logger.writeNew();
tel.addPitch(0.5, 2);    % the Cube rebooted: its clock started again
logger.stop();
log = readtable(logger.File);
verifyEqual(tc, log.pitch_deg', [1 2])
end

function testOutputsLoggedAfterRebootFromLongUptime(tc)
% Up for 40 minutes, then a reboot. The outputs must still be logged after it.
tel = tc.TestData.tel;
logger = tc.TestData.logger;
logger.start();
tel.addOutputsUsec(2400e6, 1600 * ones(1, 16));
tel.addPitch(2400, 1);
logger.writeNew();
tel.addPitch(1, 2);                            % rebooted
tel.addOutputsUsec(1e6, 1500 * ones(1, 16));
tel.addOutputsUsec(1.05e6, 1500 * ones(1, 16));
tel.addPitch(1.05, 3);
logger.stop();
log = readtable(logger.File);
verifyEqual(tc, log.pitch_deg', [1 2 3])
verifyEqual(tc, log.elevator_out_us', [1600 1500 1500])
end

function testExtraSignalsAndMarkers(tc)
% Lua values listed in logging.extraSignals get a column each, and a run
% marker goes in the row where it was made, quoted, commas and all.
tel = tc.TestData.tel;
servos = struct("name", {"Elevator"}, "output", {5});
logger = CsvLogger(tel, servos, tc.TestData.folder, ["DEMO", "CG_MODE"]);
tc.addTeardown(@() logger.stop());
logger.start();
tel.addNamedValue("DEMO", 1.25, 99.9);
tel.addPitch(100.00, 1);
pause(0.3)
tel.addMarker("run 1, 10 m/s");
pause(0.05)
tel.addPitch(100.35, 2);
tel.addNamedValue("DEMO", 2.5, 100.36);
tel.addPitch(100.40, 3);
logger.stop();
log = readtable(logger.File, TextType="string", Delimiter=",");
verifyEqual(tc, string(log.Properties.VariableNames(end-2:end)), ["DEMO", "CG_MODE", "marker"])
verifyEqual(tc, log.DEMO', [1.25 1.25 2.5])
verifyTrue(tc, all(isnan(log.CG_MODE)), "Never sent, so empty.")
verifyEqual(tc, log.marker(2), "run 1, 10 m/s")
verifyEqual(tc, log.marker(1), "log started")
verifyTrue(tc, ismissing(log.marker(3)) || log.marker(3) == "")
% And plain readtable, as a student would use it, keeps the markers as text.
plain = readtable(logger.File);
verifyEqual(tc, string(plain.marker(2)), "run 1, 10 m/s")
end

