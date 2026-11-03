% End to end: CubeGUI (Cube source) -> kahuna_relay.py -> ArduPlane SITL running cubegui.lua.
%
% Start start_sitl.sh and kahuna_relay.py first (see README.md here), then
% in MATLAB, from the CubeGUI folder:
%     run("tools/sitl/test_cubegui_end_to_end.m")
repo = fileparts(fileparts(fileparts(mfilename("fullpath"))));
if repo == ""
    repo = pwd;
end
addpath(repo);
c = jsondecode(fileread(fullfile(repo, "config", "cubegui.json")));
c.connection = struct("localPort", 14561, "cubeAddress", "127.0.0.1", "cubePort", 14565);
c.logging.folder = string(tempname);
c.level = 3;
c.logging.extraSignals = ["CG_MODE", "CG_TGT", "CG_ELEV"];
f = tempname + ".json"; writelines(jsonencode(c), f);
app = CubeGUI(ConfigFile=f); drawnow; pause(1);
app.connect("Cube (Wi-Fi)"); pause(8);
cube = app.Cube; tel = app.Telemetry;
report = @(name, ok, detail) fprintf("%s %s  [%s]\n", string(ifelse(ok, "PASS", "FAIL")), name, detail);
report("heard SITL", tel.HeartbeatCount > 3, "heartbeats " + tel.HeartbeatCount);
report("script parameters read", ~isnan(tel.param("CGUI_KP")), "CGUI_KP = " + tel.param("CGUI_KP"));
m = cube.mode();
report("script reporting", m.script, "mode " + m.name + ", rc " + m.rc);
report("RC channels arriving", ~isnan(cube.latest("rc3")), "rc3 = " + cube.latest("rc3"));
report("elevator limits from the Cube", cube.servo("Elevator").ready, mat2str([cube.servo("Elevator").minPwm cube.servo("Elevator").maxPwm]));
app.setSafety(false, false); pause(2);
sent = app.commandServo(1, 1700); pause(1.5);
[~, out] = tel.Outputs.data();
report("CubeGUI drives output 5", sent == 1700 && out(end, 5) == 1700, sprintf("sent %g, out5 %d", sent, out(end, 5)));
cube.setPitchTarget(10); cube.requestMode("closed loop"); pause(3);
m = cube.mode(); [~, out] = tel.Outputs.data();
report("closed loop on request", m.code == 2 && m.target == 10, "mode " + m.name + ", target " + m.target);
report("elevator handed to the script", ~cube.servo("Elevator").ready && out(end, 5) ~= 1700, ...
    "why: " + cube.servo("Elevator").why + ", out5 " + out(end, 5));
report("CubeGUI's command refused while the script drives", isnan(app.commandServo(1, 1300)), "");
cube.mark("e2e run 1, closed loop"); pause(1);
cube.requestMode("gui"); pause(3);
m = cube.mode(); [~, out] = tel.Outputs.data();
report("back to CubeGUI", m.code == 0 && cube.servo("Elevator").ready, "mode " + m.name);
report("slider caught up with the servo", abs(cube.servoTarget("Elevator") - cube.latest("Elevator")) < 2, ...
    sprintf("target %.1f, output %.1f", cube.servoTarget("Elevator"), cube.latest("Elevator")));
file = app.Logger.File;
app.close();
log = readtable(file, TextType="string", Delimiter=",");
report("log has the script's columns", all(ismember(["CG_MODE", "CG_TGT", "CG_ELEV"], log.Properties.VariableNames)), "");
report("log saw closed loop", any(log.CG_MODE == 2), "rows with CG_MODE 2: " + sum(log.CG_MODE == 2));
report("marker in the log", any(string(log.marker) == "e2e run 1, closed loop"), "");
fprintf("log: %s\ntimers left %d\n", file, numel(timerfindall));
function out = ifelse(c, a, b)
if c, out = a; else, out = b; end
end
