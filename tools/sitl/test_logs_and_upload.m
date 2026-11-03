% The Logs panel's Cube log controls, the log download, and installing
% cubegui.lua over MAVFTP, against SITL through kahuna_relay.py (see README.md).
%
%   run("tools/sitl/test_logs_and_upload.m")
%
% Takes a few minutes: SITL sends logs at USB speed, so the download time
% here says nothing about the Wi-Fi.
repo = fullfile(fileparts(mfilename("fullpath")), "..", "..");
addpath(repo);
c = jsondecode(fileread(fullfile(repo, "config", "cubegui.json")));
c.connection = struct("localPort", 14561, "cubeAddress", "127.0.0.1", "cubePort", 14565);
c.logging.folder = string(tempname);
c.level = 2;
f = tempname + ".json"; writelines(jsonencode(c), f);
app = CubeGUI(ConfigFile=f); drawnow; pause(1);
app.connect("Cube (Wi-Fi)"); pause(8);
src = app.Source; tel = app.Telemetry; logs = src.Logs;
report = @(name, ok, detail) fprintf("%s %s  [%s]\n", string(ifelse(ok, "PASS", "FAIL")), name, detail);
report("heard SITL", tel.HeartbeatCount > 3, "heartbeats " + tel.HeartbeatCount);

% ---- Start, stop and start again (LOG_DISARMED), without a download --------
src.setParam("LOG_DISARMED", 1); pause(6);
listLogs(src); a = logs.newest(); pause(4);
listLogs(src); b = logs.newest();
report("recording: the log grows", b.size - a.size > 100000, sprintf("%d bytes in 4 s", b.size - a.size));
src.setParam("LOG_DISARMED", 0); pause(3);
listLogs(src); c1 = logs.newest(); pause(4);
listLogs(src); c2 = logs.newest();
report("stopped: the log stops growing", c2.size - c1.size < 5000, sprintf("%d bytes in 4 s", c2.size - c1.size));
src.setParam("LOG_DISARMED", 1); pause(4);
listLogs(src); d = logs.newest();
report("started again: the same file carries on", d.id == c2.id && d.size > c2.size, ...
    sprintf("log %d, then log %d", c2.id, d.id));
src.setParam("LOG_DISARMED", 0); pause(3);

% ---- Download the newest log ---------------------------------------------------
listLogs(src); e = logs.newest();
file = fullfile(c.logging.folder, "sitl_download.BIN");
if ~isfolder(c.logging.folder)
    mkdir(c.logging.folder);
end
t = tic;
src.sendLogRequests(logs.download(e.id, e.size, file));
while logs.State == "downloading" && toc(t) < 600
    pause(0.5)
end
info = dir(file);
fid = fopen(file); head = fread(fid, 2, "*uint8")'; fclose(fid);
report("download complete", logs.State == "done" && info.bytes == e.size, ...
    sprintf("%s, %d of %d bytes in %.0f s", logs.State, info.bytes, e.size, toc(t)));
report("download is a .BIN file", isequal(head, uint8([163 149])), mat2str(head));

% ---- Copy cubegui.lua over MAVFTP --------------------------------------------
onCube = fullfile(repo, "tools", "sitl", "run", "scripts", "cubegui.lua");
writelines("-- emptied by test_logs_and_upload.m", onCube);
src.ScriptFolder = "scripts";   % SITL's scripts folder (on a Cube it's /APM/scripts)
fid = fopen(fullfile(repo, "lua", "cubegui.lua")); data = fread(fid, Inf, "*uint8"); fclose(fid);
t = tic;
src.sendFtp(src.Upload.start(src.ScriptFolder + "/cubegui.lua", data));
while src.Upload.State == "uploading" && toc(t) < 60
    pause(0.2)
end
fid = fopen(onCube); copied = fread(fid, Inf, "*uint8"); fclose(fid);
report("upload complete and identical", src.Upload.State == "done" && isequal(copied, data), ...
    sprintf("%s in %.1f s, %d bytes", src.Upload.State, toc(t), numel(copied)));
pause(6);   % the window restarts the scripts once the copy is done
report("script reporting after the restart", tel.secondsSinceNamed("CG_MODE") < 2, ...
    sprintf("CG_MODE %.1f s ago", tel.secondsSinceNamed("CG_MODE")));

app.close();
fprintf("timers left %d\n", numel(timerfindall));

function listLogs(src)
% Ask the Cube for its list of logs, and wait for it.
src.sendLogRequests(src.Logs.list());
t = tic;
while src.Logs.State == "listing" && toc(t) < 10
    pause(0.2)
end
end

function out = ifelse(c, a, b)
if c, out = a; else, out = b; end
end
