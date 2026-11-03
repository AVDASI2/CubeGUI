function tests = testCube
%TESTCUBE  Checks the cube object that panels are given (engine/Cube.m).
%
%   Run with:  runtests("tests")
tests = functiontests(localfunctions);
end

function setupOnce(tc)
root = fullfile(fileparts(mfilename("fullpath")), "..");
addpath(fullfile(root, "engine"));
tc.TestData.root = root;
end

function setup(tc)
config = loadConfig(fullfile(tc.TestData.root, "config", "cubegui.json"));
tel = Telemetry(30, 20);
tc.TestData.tel = tel;
tc.TestData.cube = Cube(tel, config.servos, 1, 30, @(text, isProblem) []);  % no status line here
tc.TestData.source = SimulatedSource(tel);
end

function teardown(tc)
delete(tc.TestData.source)
verifyEmpty(tc, timerfindall, "A test left a timer running.")
delete(timerfindall)
end

function connected = connect(tc)
% Connect the simulation and hand it to the cube, as the window does.
src = tc.TestData.source;
src.connect();
src.requestParams("SERVO" + [5 6 7]' + ["_MIN", "_TRIM", "_MAX"]);
tc.TestData.cube.attach(src);
connected = src;
end

function testNothingSentBeforeConnecting(tc)
cube = tc.TestData.cube;
cube.moveServo("Elevator", 1700);
verifyFalse(tc, cube.isConnected())
verifyFalse(tc, cube.servo("Elevator").ready)
verifyEqual(tc, cube.servoTarget("Elevator"), 1700)   % remembered, but not sent
end

function testServoDetails(tc)
connect(tc);
s = tc.TestData.cube.servo("elevator");     % names aren't case-sensitive
verifyEqual(tc, s.output, 5)
verifyEqual(tc, s.units, "µs")
verifyEqual(tc, s.range, [1100 1900])
verifyEqual(tc, s.trim, 1500)
verifyTrue(tc, s.ready)
verifyEqual(tc, [s.minPwm s.trimPwm s.maxPwm], [1100 1500 1900])
end

function testMoveServoIsRateLimited(tc)
% Two commands 10 ms apart: the first goes now, the second on the next
% tick after 0.1 s, so the last position is never lost.
src = connect(tc);
cube = tc.TestData.cube;
cube.moveServo("Elevator", 1700);
verifyEqual(tc, src.Commanded(5), 1700)
cube.moveServo("Elevator", 1300);
verifyEqual(tc, src.Commanded(5), 1700, "Too soon: should wait.")
pause(0.15)
cube.tick();
verifyEqual(tc, src.Commanded(5), 1300)
end

function testZeroAllUsesTheCubesTrim(tc)
src = connect(tc);
cube = tc.TestData.cube;
cube.sendNow("Rudder", 1820);
cube.zeroAll();
verifyEqual(tc, src.Commanded([5 6 7]), [1500 1500 1500])
verifyEqual(tc, cube.servoTarget("Rudder"), 1500)
end

function testSignals(tc)
connect(tc);
cube = tc.TestData.cube;
pause(1.5)
[t, y] = cube.history("pitch");
verifyGreaterThan(tc, numel(t), 10)
verifyEqual(tc, t(end), 0)
verifyTrue(tc, isfinite(y(end)) && isfinite(cube.latest("pitch")))
verifyFalse(tc, isnan(cube.latest("pitch rate")))
verifyEqual(tc, cube.units("pitch rate"), "deg/s")
verifyFalse(tc, isnan(cube.latest("Elevator")))     % the Cube's report, in µs
verifyFalse(tc, isnan(cube.latest("DEMO")))         % a pretend Lua value
verifyTrue(tc, isnan(cube.latest("NOT_SENT")))      % nothing called that
end

function testUnknownServoNamed(tc)
verifyError(tc, @() tc.TestData.cube.moveServo("Aileron", 10), "CubeGUI:servo")
end

function testWhoIsInCharge(tc)
% The script's reports decide which servos CubeGUI can drive.
connect(tc);
cube = tc.TestData.cube;
tel = tc.TestData.tel;
verifyFalse(tc, cube.mode().script, "No script heard yet.")
verifyTrue(tc, cube.servo("Elevator").ready)

tel.addNamedValue("CG_MODE", 2, 1);    % closed loop: the elevator is the script's
tel.addNamedValue("CG_RC", 0, 1);
m = cube.mode();
verifyTrue(tc, m.script)
verifyEqual(tc, m.name, "Closed loop")
verifyFalse(tc, cube.servo("Elevator").ready)
verifyEqual(tc, cube.servo("Elevator").why, "the closed loop is driving it.")
verifyTrue(tc, cube.servo("Rudder").ready, "The closed loop only drives the elevator.")

tel.addNamedValue("CG_MODE", 1, 2);    % RC: by default sticks drive outputs 5 and 6
verifyFalse(tc, cube.servo("Elevator").ready)
verifyFalse(tc, cube.servo("Rudder").ready)
verifyTrue(tc, cube.servo("Gear").ready)
verifyTrue(tc, contains(cube.servo("Rudder").why, "transmitter"))
end

function testClosedLoopHandedBackBelowLevel2(tc)
% Left in closed loop by a higher level, the script is asked to hand the
% elevator back, because a level 1 window has no button to do it.
src = connect(tc);
cube = tc.TestData.cube;
tc.TestData.tel.addNamedValue("CG_MODE", 2, 1);
verifyEqual(tc, cube.mode().name, "Closed loop")
cube.tick();
% The simulation behaves like the script once it gets a command, and
% reports CG_MODE 0 within a fifth of a second.
started = tic;
while cube.mode().code ~= 0 && toc(started) < 3
    pause(0.1)
end
verifyEqual(tc, cube.mode().name, "CubeGUI")
verifyTrue(tc, cube.servo("Elevator").ready)
end

function testRcSignals(tc)
tel = tc.TestData.tel;
cube = tc.TestData.cube;
tel.addRc(1.0, [1500 1600 1000 1900 zeros(1, 14)]);
verifyEqual(tc, cube.latest("rc2"), 1600)
verifyEqual(tc, cube.latest("RC4"), 1900)
verifyEqual(tc, cube.units("rc1"), "us")
end

