function tests = testCubeGuiApp
%TESTCUBEGUIAPP  Checks the CubeGUI window end to end, with the Simulated source.
%
%   Run with:  runtests("tests")
%   Windows open and close by themselves while it runs.
tests = functiontests(localfunctions);
end

function setupOnce(~)
addpath(fullfile(fileparts(mfilename("fullpath")), ".."));
end

function setup(tc)
% Use the shipped settings, but log into a temporary folder so tests don't
% fill CubeGUI's own logs folder.
root = fullfile(fileparts(mfilename("fullpath")), "..");
config = jsondecode(fileread(fullfile(root, "config", "cubegui.json")));
tc.TestData.logFolder = string(tempname);
config.logging.folder = tc.TestData.logFolder;
config.level = 3;   % everything, so every feature can be tested
configFile = tempname + ".json";
writelines(jsonencode(config), configFile);
tc.TestData.app = CubeGUI(ConfigFile=configFile);
% Let MATLAB finish drawing the new window before any test times anything:
% the first draw takes a second or two, and holds up the timers meanwhile.
drawnow
pause(0.5)
end

function teardown(tc)
tc.TestData.app.close();
verifyEmpty(tc, timerfindall, "Closing the window left a timer running.")
delete(timerfindall)
end

function testOpensDisconnected(tc)
app = tc.TestData.app;
verifyEmpty(tc, app.Source)
verifyTrue(tc, isvalid(app.Figure))
end

function testConnectSimulated(tc)
app = tc.TestData.app;
app.connect("Simulated");
verifyClass(tc, app.Source, "SimulatedSource")
% Measure the steady rate over the last second. (The first second or so
% can be slow while MATLAB finishes drawing a new window.)
pause(2.5)
[t, ~] = app.Telemetry.Pitch.data();
verifyGreaterThanOrEqual(tc, sum(t > t(end) - 1), 17, "Simulated pitch should arrive at about 20 Hz.")
verifyLessThan(tc, app.Telemetry.secondsSinceHeartbeat(), 2)
end

function testServoCommandUsesPwmAndClamps(tc)
app = tc.TestData.app;
app.connect("Simulated");
verifyEqual(tc, app.commandServo(1, 1700), 1700)
verifyEqual(tc, app.commandServo(1, 1100), 1100)
verifyEqual(tc, app.commandServo(1, 2400), 1900)   % beyond MAX: held at MAX
verifyEqual(tc, app.Source.Commanded(5), 1900)
verifyEqual(tc, app.commandServo(2, 1300), 1300)   % rudder, output 6
verifyEqual(tc, app.Source.Commanded(6), 1300)
end

function testZeroAllSendsTrim(tc)
app = tc.TestData.app;
app.connect("Simulated");
app.commandServo(1, 1820);
app.commandServo(3, 1180);
app.zeroAll();
verifyEqual(tc, app.Source.Commanded([5 6 7]), [1500 1500 1500])
end

function testServosOffUntilConnected(tc)
% Nothing to drive until the Cube's limits arrive.
app = tc.TestData.app;
verifyTrue(tc, isnan(app.commandServo(1, 1700)))
end

function testLimitsFollowTheCube(tc)
% The slider's ends are the Cube's SERVOn_MIN/MAX, and follow a change made
% in the Setup tab.
app = tc.TestData.app;
app.connect("Simulated");
app.setNewValue("SERVO7_MAX", 1800);
app.applySetup(false);
pause(0.5)
verifyEqual(tc, app.commandServo(3, 1850), 1800)   % held at the new MAX
verifyEqual(tc, app.commandServo(3, 1650), 1650)
verifyEqual(tc, app.commandServo(1, 1900), 1900)   % the elevator is unchanged
end

function testOutOfRangeLimitsSwitchServoOff(tc)
% A limit outside 1000 to 2000 us: that servo isn't driven at all.
app = tc.TestData.app;
app.connect("Simulated");
app.setNewValue("SERVO6_MAX", 2100);
app.applySetup(false);
offLabel = @() any(string({findall(app.Figure, "Type", "uilabel").Text}) == ...
    "Its limits on the Cube need fixing.");
waitUntil(@() any(isnan(app.Source.ServoLimits(6, :))) && offLabel(), 5);
verifyTrue(tc, isnan(app.commandServo(2, 1700)))
verifyTrue(tc, any(isnan(app.Source.ServoLimits(6, :))))
verifyTrue(tc, offLabel())
% Put right, it comes back.
app.setNewValue("SERVO6_MAX", 1900);
app.applySetup(false);
waitUntil(@() ~any(isnan(app.Source.ServoLimits(6, :))), 5);
verifyEqual(tc, app.commandServo(2, 1900), 1900)
end

function testNothingSentWhenDisconnected(tc)
app = tc.TestData.app;
verifyTrue(tc, isnan(app.commandServo(1, 1700)))
end

function testSetupReadsAndApplies(tc)
app = tc.TestData.app;
app.connect("Simulated");
% Beyond the guide, CubeGUI also wants SCR_ENABLE = 1 and THR_FAILSAFE = 2
% for cubegui.lua (level 2). Set them, as a student would.
setUpForLevel3(app);
verifyEqual(tc, app.Telemetry.param("SERVO6_FUNCTION"), 0)
verifyEmpty(tc, app.setupChanges(), "A Cube set up as the guide says needs no changes.")
% Make the simulated Cube need a change, then Apply it (without the dialog).
app.Source.setParam("SERVO6_FUNCTION", 19);   % output 6 taken by the elevator function
changes = app.setupChanges();
verifyEqual(tc, [changes.name], "SERVO6_FUNCTION")
app.applySetup(false);
verifyEqual(tc, app.Telemetry.param("SERVO6_FUNCTION"), 0)
verifyEmpty(tc, app.setupChanges())
end

function testVersionShown(tc)
app = tc.TestData.app;
app.connect("Simulated");
verifyEqual(tc, app.Telemetry.Version.firmware, "Simulated (no Cube)")
end

function testDisconnectStopsSource(tc)
app = tc.TestData.app;
app.connect("Simulated");
app.disconnect();
verifyEmpty(tc, app.Source)
% Only the window's own redraw timer should be left.
verifyEqual(tc, numel(timerfindall), 1)
end

function testCloseRequestShutsDown(tc)
% Closing with the window's X calls the same shutdown.
app = tc.TestData.app;
app.connect("Simulated");
close(app.Figure)
verifyFalse(tc, isvalid(app.Figure))
verifyEmpty(tc, app.Source)
end

function testLogsWhileConnected(tc)
app = tc.TestData.app;
app.connect("Simulated");
pause(2)
app.commandServo(1, 1700);
pause(1)
app.disconnect();
files = dir(fullfile(tc.TestData.logFolder, "CubeGUI_*.csv"));
verifyNumElements(tc, files, 1, "Connecting should start exactly one log file.")
log = readtable(fullfile(files(1).folder, files(1).name));
verifyGreaterThan(tc, height(log), 40)
verifyEqual(tc, log.elevator_cmd_us(end), 1700)
verifyEqual(tc, log.elevator_out_us(end), 1700)
end

function testTypedValueIsWrittenAndConfirmed(tc)
app = tc.TestData.app;
app.connect("Simulated");
setUpForLevel3(app);   % see testSetupReadsAndApplies
app.setNewValue("SERVO5_MAX", 1950);
changes = app.setupChanges();
verifyEqual(tc, [changes.name], "SERVO5_MAX")
verifyEqual(tc, changes.to, 1950)
app.applySetup(false);
verifyEqual(tc, app.Telemetry.param("SERVO5_MAX"), 1950)
pause(1.5)   % the window checks writes once a second
verifyEmpty(tc, app.setupChanges(), "Once confirmed, the typed value should be cleared.")
end

function testReadOnlyParameterRefused(tc)
app = tc.TestData.app;
app.connect("Simulated");
verifyError(tc, @() app.setNewValue("SERIAL1_BAUD", 115), "CubeGUI:param")
end

function testAddParameter(tc)
app = tc.TestData.app;
app.connect("Simulated");
app.addParameter("servo8_function");   % lower case is fine
app.setNewValue("SERVO8_FUNCTION", 0); % it's now in the table, so this works
verifyEqual(tc, app.Telemetry.param("SERVO8_FUNCTION"), 0)
end

function testSafetySwitch(tc)
app = tc.TestData.app;
app.connect("Simulated");
pause(1.2)
verifyEqual(tc, app.Telemetry.SafetyOn, true, "Like a real Cube, safety starts on.")
app.setSafety(false, false);
verifyEqual(tc, app.Telemetry.SafetyOn, false)
app.setSafety(true);
verifyEqual(tc, app.Telemetry.SafetyOn, true)
end

function testRebootFromCubeGUI(tc)
% Rebooting the (simulated) Cube: the window notices, and the safety switch
% is on again.
app = tc.TestData.app;
app.connect("Simulated");
app.setSafety(false, false);
pause(4)                         % long enough for the clock going back to show
app.Source.reboot();
pause(1.5)
verifyEqual(tc, app.Telemetry.RebootCount, 1)
verifyEqual(tc, app.Telemetry.SafetyOn, true, "The safety switch is on after a reboot.")
labels = findall(app.Figure, "Type", "uilabel");
verifyTrue(tc, any(startsWith(string({labels.Text}), "The Cube restarted")))
end

function testRebootIsReported(tc)
app = tc.TestData.app;
app.connect("Simulated");
pause(1)
% A pitch sample far in the future, so the simulation's next one looks
% like the clock going backwards: a reboot.
app.Telemetry.addPitch(1e6, 0);
pause(1)
verifyEqual(tc, app.Telemetry.RebootCount, 1)
labels = findall(app.Figure, "Type", "uilabel");
verifyTrue(tc, any(startsWith(string({labels.Text}), "The Cube restarted")))
end

function testElevatorDoesNothingWithSafetyOn(tc)
% In the simulation, as on the rig, the servo is held while safety is on.
app = tc.TestData.app;
app.connect("Simulated");
app.commandServo(1, 1900);
% Average over one whole 4 s swing, so the swing itself averages out.
pause(4.5)
held = meanPitchOver(app, 4);
app.setSafety(false, false);
pause(5)
live = meanPitchOver(app, 4);
verifyLessThan(tc, abs(held), 1.5, "With safety on, the elevator shouldn't move the pitch.")
verifyGreaterThan(tc, live, held + 5, "With safety off, full up elevator should raise the pitch.")
end

function m = meanPitchOver(app, seconds)
% The pitch averaged over time (not over samples), so a stretch with fewer
% samples, while MATLAB was busy, doesn't tip the average.
[t, p] = app.Telemetry.Pitch.data();
keep = t > t(end) - seconds;
t = t(keep);
m = trapz(t, p(keep, 1)) / (t(end) - t(1));
end

% ---- Panels and levels ------------------------------------------------------

function app = openWith(tc, change)
% A window from the shipped settings, changed by change(config).
root = fullfile(fileparts(mfilename("fullpath")), "..");
config = jsondecode(fileread(fullfile(root, "config", "cubegui.json")));
config.logging.folder = tc.TestData.logFolder;
config = change(config);
configFile = tempname + ".json";
writelines(jsonencode(config), configFile);
tc.TestData.app.close();           % the one setup opened
app = CubeGUI(ConfigFile=configFile);
tc.TestData.app = app;             % so teardown closes this one
drawnow
pause(0.5)
end

function folder = writePanels(tc)
% Two broken panels in a temporary folder on the path: one that fails as
% it opens, and one whose update fails.
folder = string(tempname);
mkdir(folder)
writelines(["function panel = brokenOpenPanel(parent, cube, options)", ...
    "panel.height = 40;", "x = [1 2 3];", "y = x(5);   % no fifth element", "end"], ...
    fullfile(folder, "brokenOpenPanel.m"));
writelines(["function panel = brokenUpdatePanel(parent, cube, options)", ...
    "uilabel(parent, Text=""I'm fine to start with"");", "panel.height = 40;", ...
    "panel.update = @() error(""This panel's update went wrong."");", "end"], ...
    fullfile(folder, "brokenUpdatePanel.m"));
addpath(folder)
tc.addTeardown(@() rmpath(folder));
end

function testBrokenPanelsAreContained(tc)
writePanels(tc);
app = openWith(tc, @(c) setfield(c, "controls", [c.controls; ...
    {struct("panel", "brokenOpenPanel"); struct("panel", "brokenUpdatePanel"); ...
    struct("panel", "noSuchPanel")}]));
app.connect("Simulated");
pause(1.5)
labels = string({findall(app.Figure, "Type", "uilabel").Text});
verifyTrue(tc, any(startsWith(labels, "brokenOpenPanel.m didn't open") & contains(labels, "line 4")))
verifyTrue(tc, any(startsWith(labels, "noSuchPanel.m didn't open: Can't find")))
verifyTrue(tc, any(startsWith(labels, "brokenUpdatePanel.m stopped updating: This panel's update went wrong.")))
% The rest of the window carries on.
[t, ~] = app.Telemetry.Pitch.data();
verifyGreaterThan(tc, numel(t), 15)
verifyEqual(tc, app.commandServo(1, 1700), 1700)
end

function testLevelZeroIsSimulatedOnly(tc)
app = openWith(tc, @(c) setfield(c, "level", 0));
verifyEqual(tc, string(app.Figure.Name), "CubeGUI, level 0 of 3: Simulate")
dropdowns = findall(app.Figure, "Type", "uidropdown");
verifyEqual(tc, string(dropdowns(1).Items), "Simulated")
tabs = findall(app.Figure, "Type", "uitab");
verifyEqual(tc, string({tabs.Title}), "Run", "No Setup tab at level 0.")
app.connect("Simulated");
pause(0.5)
verifyFalse(tc, app.Logger.IsLogging, "No logging below level 1.")
verifyEqual(tc, app.commandServo(1, 1900), 1900, "Sliders still drive the simulation.")
end

function testLevelOneHasUsbAndFirmware(tc)
% Level 1 offers the Cube over the Wi-Fi and, from R2026b, over USB, and
% the Setup tab has the Firmware over USB box.
app = openWith(tc, @(c) setfield(c, "level", 1));
dropdowns = findall(app.Figure, "Type", "uidropdown");
sources = dropdowns(arrayfun(@(d) any(strcmp(d.Items, "Simulated")), dropdowns));
if isMATLABReleaseOlderThan("R2026b")
    verifyEqual(tc, string(sources.Items), ["Simulated", "Cube (Wi-Fi)"])
else
    verifyEqual(tc, string(sources.Items), ["Simulated", "Cube (Wi-Fi)", "Cube (USB)"])
end
panels = findall(app.Figure, "Type", "uipanel", "Title", "Firmware over USB");
verifyEqual(tc, numel(panels), 1)
verifyEqual(tc, string(panels.Visible), "on")
end

function testUnreleasedLevelsSayPreview(tc)
% Levels in the code but not yet released say so, in the title and the status line.
app = openWith(tc, @(c) setfield(c, "level", 2));
verifyEqual(tc, string(app.Figure.Name), "CubeGUI, level 2 of 3: RC (preview: not released yet)")
labels = string({findall(app.Figure, "Type", "uilabel").Text});
verifyTrue(tc, any(startsWith(labels, "Level 2 is a preview")))
app = openWith(tc, @(c) setfield(c, "level", 1));
verifyEqual(tc, string(app.Figure.Name), "CubeGUI, level 1 of 3: Connect and log")
end

function testPanelsHaveLevels(tc)
% The shipped settings show the pitch rate panel from level 1.
app = openWith(tc, @(c) setfield(c, "level", 0));
labels = string({findall(app.Figure, "Type", "uipanel").Title});
verifyFalse(tc, any(labels == "Pitch rate"))
app = openWith(tc, @(c) setfield(c, "level", 1));
labels = string({findall(app.Figure, "Type", "uipanel").Title});
verifyTrue(tc, any(labels == "Pitch rate"))
end

function testClosedLoopInSimulation(tc)
% Level 3, with the Simulated source behaving like cubegui.lua: the closed
% loop takes the elevator, holds a pitch target, and gives it back.
app = openWith(tc, @(c) setfield(c, "level", 3));
app.connect("Simulated");
app.setSafety(false, false);
pause(1)
verifyTrue(tc, app.Cube.mode().script, "The simulated script should be reporting.")
app.Cube.setPitchTarget(4);
app.Cube.requestMode("closed loop");
pause(8)
verifyEqual(tc, app.Cube.mode().name, "Closed loop")
verifyFalse(tc, app.Cube.servo("Elevator").ready)
verifyTrue(tc, isnan(app.commandServo(1, 1700)), "CubeGUI can't drive the elevator in closed loop.")
verifyEqual(tc, meanPitchOver(app, 4), 4, "The closed loop should hold the target.", AbsTol=1.5)
app.Cube.requestMode("gui");
pause(1)
verifyEqual(tc, app.Cube.mode().name, "CubeGUI")
verifyFalse(tc, isnan(app.commandServo(1, 1500)), "Back to CubeGUI.")
labels = string({findall(app.Figure, "Type", "uilabel").Text});
verifyFalse(tc, any(contains(labels, ["didn't open", "stopped updating"])))
end

function testMarkerGoesInLog(tc)
app = openWith(tc, @(c) setfield(c, "level", 1));
app.connect("Simulated");
pause(1)
app.Cube.mark("run 1: 10 m/s");
pause(1.5)
app.disconnect();
files = dir(fullfile(tc.TestData.logFolder, "CubeGUI_*.csv"));
log = readtable(fullfile(files(1).folder, files(1).name), TextType="string", Delimiter=",");
verifyEqual(tc, sum(log.marker == "run 1: 10 m/s"), 1)
end

function testLaptopLogStartsAndStops(tc)
% The Logs panel's Laptop button stops the CSV log and starts a new one.
app = openWith(tc, @(c) setfield(c, "level", 1));
app.connect("Simulated");
pause(1)
verifyTrue(tc, app.Logger.IsLogging, "Logging starts on connecting, as the settings say.")
logs = findall(app.Figure, "Type", "uipanel", "Title", "Logs");
laptop = findall(logs, "Type", "uibutton", "Text", "Stop");
verifyNumElements(tc, laptop, 1)
feval(laptop.ButtonPushedFcn, [], []);
pause(0.3)
verifyFalse(tc, app.Logger.IsLogging)
verifyEqual(tc, string(laptop.Text), "Start")
feval(laptop.ButtonPushedFcn, [], []);
pause(1.2)
verifyTrue(tc, app.Logger.IsLogging)
app.disconnect();
files = dir(fullfile(tc.TestData.logFolder, "CubeGUI_*.csv"));
verifyNumElements(tc, files, 2, "Stop then Start makes a second file.")
end

function setUpForLevel3(app)
% The parameters CubeGUI wants beyond the guide's state, by level 3.
app.Source.setParam("SCR_ENABLE", 1);
app.Source.setParam("THR_FAILSAFE", 2);
end

function waitUntil(condition, seconds)
% Wait until condition() is true, or seconds have gone by. Better than a
% fixed pause when the window may be slow to update.
started = tic;
while ~condition() && toc(started) < seconds
    pause(0.1)
end
end

function testCalibrationPanel(tc)
% Click through a 3-step calibration in the simulation, as a student would.
app = openWith(tc, @(c) setfield(c, "controls", {struct("panel", "calibrationPanel", ...
    "servo", "Elevator", "steps", 3)}));
app.connect("Simulated");
app.setSafety(false, false);
pause(1)
calibration = findall(app.Figure, "Type", "uipanel", "Title", "Calibrate Elevator");
openButton = findall(calibration, "Type", "uibutton", "Text", "Open calibration...");
feval(openButton.ButtonPushedFcn, [], []);   % the calibration opens in its own window
window = findall(groot, "Type", "figure", "Name", "Calibrate Elevator");
verifyNumElements(tc, window, 1)
buttons = findall(window, "Type", "uibutton");
press = @(text) feval(buttons(string({buttons.Text}) == text).ButtonPushedFcn, [], []);
angleBox = findall(window, "Type", "uinumericeditfield");
press("Start");
pause(0.3)
verifyEqual(tc, app.Source.Commanded(5), 1100, "Step 1 is SERVO5_MIN.")
for angle = [-20 1 20 3 -20]          % 1100 1500 1900 1500 1100
    angleBox.Value = angle;
    press("Record");
    pause(0.15)
end
box = findall(window, "Type", "uitextarea");
settings = strjoin(string(box.Value), " ");
verifyTrue(tc, contains(settings, "[-20.0, 1100], [2.0, 1500], [20.0, 1900]"), settings)
texts = {findall(window, "Type", "uilabel").Text};   % a label's text can be several lines
labels = string(cellfun(@(t) strjoin(string(t), " "), texts, UniformOutput=false));
verifyTrue(tc, any(startsWith(labels, "Next: click Copy settings")))
table = findall(window, "Type", "uitable");
verifyEqual(tc, table.Data{:, 4}', ["-20.0" "1.0" "20.0" "3.0" "-20.0"], "The steps table shows each angle.")
verifyTrue(tc, any(contains(labels, "Hysteresis: up to 2.0 deg")))
% Back after the end measures the last step again, and Record works again.
record = buttons(string({buttons.Text}) == "Record");
verifyEqual(tc, string(record.Enable), "off")
press("Back");
pause(0.3)
verifyEqual(tc, string(record.Enable), "on", "Back after the end should allow recording again.")
verifyEqual(tc, app.Source.Commanded(5), 1100, "The last step is back at SERVO5_MIN.")
verifyEqual(tc, box.Value, {''}, "The old result is cleared.")
angleBox.Value = -19;
press("Record");
pause(0.15)
verifyEqual(tc, string(record.Enable), "off")
verifyNotEmpty(tc, strjoin(string(box.Value), ""), "Finished again, with a new result.")
% Closing CubeGUI closes the calibration window too.
app.close();
verifyFalse(tc, isvalid(window), "The calibration window should close with CubeGUI.")
end

