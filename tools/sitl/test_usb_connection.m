% CubeGUI's Cube (USB) source against SITL, through usb_relay.py,
% which stands in for the USB cable with a pseudo serial port (see README.md).
%
%   python3 tools/sitl/usb_relay.py /tmp/usb_port      (instead of kahuna_relay.py)
%   run("tools/sitl/test_usb_connection.m")
repo = fullfile(fileparts(mfilename("fullpath")), "..", "..");
addpath(repo, fullfile(repo, "engine"));
port = strtrim(fileread("/tmp/usb_port"));
c = jsondecode(fileread(fullfile(repo, "config", "cubegui.json")));
c.logging.folder = string(tempname);
c.level = 1;
f = tempname + ".json"; writelines(jsonencode(c), f);
report = @(name, ok, detail) fprintf("%s %s  [%s]\n", string(ifelse(ok, "PASS", "FAIL")), name, detail);
found = CubeSource.findMavlink(port, 1.5);
report("port labelled MAVLink by listening", found == "MAVLink", found);
app = CubeGUI(ConfigFile=f); drawnow; pause(1);
app.connect("Cube (USB)", port); pause(8);
tel = app.Telemetry;
report("heard SITL over the serial port", tel.HeartbeatCount > 3, "heartbeats " + tel.HeartbeatCount);
labels = string({findall(app.Figure, "Type", "uilabel").Text});
report("status names the USB port", any(contains(labels, "Cube on USB (" + port + ")")), port);
report("parameters read", ~isnan(tel.param("SERVO5_MAX")), "SERVO5_MAX = " + tel.param("SERVO5_MAX"));
[t, ~] = tel.Pitch.data();
report("pitch at about 20 Hz", sum(t > t(end) - 1) >= 15, sum(t > t(end) - 1) + " in the last second");
app.setSafety(false, false); pause(2);
sent = app.commandServo(1, 1700); pause(1.5);
[~, out] = tel.Outputs.data();
report("servo command over USB", sent == 1700 && out(end, 5) == 1700, sprintf("sent %g, out5 %d", sent, out(end, 5)));
app.Source.setParam("LOG_DISARMED", 0); pause(1);
app.Source.sendLogRequests(app.Source.Logs.list());
t0 = tic; while app.Source.Logs.State == "listing" && toc(t0) < 10, pause(0.2); end
report("log list over USB", ~isempty(app.Source.Logs.Entries), numel(app.Source.Logs.Entries) + " logs");
app.close();
fprintf("timers left %d\n", numel(timerfindall));
function out = ifelse(c, a, b)
if c, out = a; else, out = b; end
end
