function step4_live_plot(options)
%STEP4_LIVE_PLOT  Milestone 4: a live, scrolling plot of the Cube's pitch.
%
%   Asks the Cube for ATTITUDE at 20 Hz, stores each pitch reading in a ring
%   buffer as it arrives, and redraws the plot from a timer 10 times a
%   second. Close the window (or press Ctrl+C) to stop.
%
%   step4_live_plot                      % fake_cube.py on this computer
%   step4_live_plot(LocalPort=14560)     % if port 14550 is taken
%   step4_live_plot(RemoteHost="192.168.4.1")  % a real Cube
%
%   This is the pattern the full CubeGUI window uses:
%     message arrives -> callback stores it (nothing else)
%     timer, 10 Hz    -> redraw the plot from the stored data

arguments
    options.RemoteHost (1,1) string = "127.0.0.1"
    options.LocalPort (1,1) double {mustBeInteger, mustBePositive} = 14550
    options.RemotePort (1,1) double {mustBeInteger, mustBePositive} = 14555
    options.RateHz (1,1) double {mustBePositive} = 20        % ATTITUDE rate to ask for
    options.WindowSeconds (1,1) double {mustBePositive} = 30 % how much history to show
    options.Duration (1,1) double {mustBePositive} = Inf     % stop after this many seconds
    options.SaveTo (1,1) string = ""                         % save a picture of the plot at the end
end

% RingBuffer lives in the engine folder, next to this one.
addpath(fullfile(fileparts(mfilename("fullpath")), "..", "engine"));

% ---- Connect (as in step2_connect) ---------------------------------------------

dialect = mavlinkdialect("common.xml");
io = mavlinkio(dialect, SystemID=255, ComponentID=190);
try
    connect(io, "UDP", LocalPort=options.LocalPort);
catch err
    shortMessage = strtrim(extractBefore(err.message + " [", " ["));
    fprintf(2, ['Couldn''t listen on UDP port %d. Is Mission Planner open?\n' ...
        'MATLAB''s message: %s\n'], options.LocalPort, shortMessage);
    return
end
cube = mavlinkclient(io, 1, 1);

% ---- Store pitch as it arrives -----------------------------------------------------

% Enough room for the whole window at double the rate asked for, in case
% messages come in faster than expected.
pitchBuffer = RingBuffer(ceil(options.WindowSeconds * options.RateHz * 2), 1);

% The callback only stores the sample. It never draws: drawing is slow, and
% a slow callback would hold up every message behind it. Time comes from
% the Cube's own clock (ms since it booted), so the plot is as smooth as
% the Cube's sampling, whatever the Wi-Fi does to arrival times.
storePitch = @(~, msg) pitchBuffer.push( ...
    double(msg.Payload.time_boot_ms) / 1000, rad2deg(double(msg.Payload.pitch)));
attitudeSub = mavlinksub(io, cube, "ATTITUDE", NewMessageFcn=storePitch); %#ok<NASGU>

% ---- The window -----------------------------------------------------------------------

fig = uifigure(Name="Step 4: live pitch", Position=[100 100 800 420]);
ax = uiaxes(fig, Position=[20 20 760 380]);
pitchLine = plot(ax, NaN, NaN, LineWidth=1.5);
ax.XLim = [-options.WindowSeconds 0];
ax.YLim = [-20 20];
ax.XGrid = "on";
ax.YGrid = "on";
xlabel(ax, "Time (s, 0 = latest)")
ylabel(ax, "Pitch (deg)")
title(ax, "Waiting for the Cube...")

% ---- Timers ---------------------------------------------------------------------------

attitudeId = msginfo(dialect, "ATTITUDE").MessageID;
heartbeat = makeHeartbeat(dialect);
rateRequest = createcmd(dialect, "long", "MAV_CMD_SET_MESSAGE_INTERVAL");
rateRequest.Payload.target_system(:) = 1;
rateRequest.Payload.target_component(:) = 1;
rateRequest.Payload.param1(:) = attitudeId;         % which message
rateRequest.Payload.param2(:) = 1e6 / options.RateHz; % interval between them, in microseconds

send = @(msg) sendudpmsg(io, msg, options.RemoteHost, options.RemotePort);

% Once a second: send our heartbeat and, if pitch is arriving too slowly,
% ask for the rate again. Asking until we get it also covers a Cube that
% reboots, which forgets any rate it was asked for.
everySecond = timer(ExecutionMode="fixedRate", Period=1, BusyMode="drop", ...
    Name="step4 heartbeat", ...
    TimerFcn=@(~, ~) heartbeatAndRate(send, heartbeat, rateRequest, pitchBuffer, options.RateHz));

% Ten times a second: redraw from the buffer.
redrawTimer = timer(ExecutionMode="fixedRate", Period=0.1, BusyMode="drop", ...
    Name="step4 redraw", ...
    TimerFcn=@(~, ~) redraw(pitchBuffer, pitchLine, ax));

cleanup = onCleanup(@() shutdown([everySecond, redrawTimer], io, fig));
start(everySecond)
start(redrawTimer)

fprintf("Plotting pitch from %s:%d. Close the window to stop.\n", ...
    options.RemoteHost, options.RemotePort);

% Wait here until the window is closed or Duration runs out. pause lets
% the timers and callbacks run while we wait.
startTime = tic;
while isvalid(fig) && toc(startTime) < options.Duration
    pause(0.1)
end

if options.SaveTo ~= "" && isvalid(fig)
    % Stop redrawing, then draw once more in full, so the picture saved is
    % up to date. (drawnow limitrate can leave the screen a frame or two behind.)
    stop(redrawTimer)
    redraw(pitchBuffer, pitchLine, ax)
    drawnow
    exportgraphics(ax, options.SaveTo);
    fprintf("Saved the plot to %s\n", options.SaveTo);
end
end

% ---- Local functions -------------------------------------------------------------------

function heartbeat = makeHeartbeat(dialect)
heartbeat = createmsg(dialect, "HEARTBEAT");
heartbeat.Payload.type(:) = enum2num(dialect, "MAV_TYPE", "MAV_TYPE_GCS");
heartbeat.Payload.autopilot(:) = enum2num(dialect, "MAV_AUTOPILOT", "MAV_AUTOPILOT_INVALID");
heartbeat.Payload.system_status(:) = enum2num(dialect, "MAV_STATE", "MAV_STATE_ACTIVE");
heartbeat.Payload.mavlink_version(:) = 3;
end

function rate = measuredRate(buffer)
% Messages per second over the last 2 s of Cube time.
[t, ~] = buffer.data();
if numel(t) < 2
    rate = 0;
    return
end
rate = sum(t > t(end) - 2) / 2;
end

function heartbeatAndRate(send, heartbeat, rateRequest, buffer, wantedHz)
% A timer stops for good if its function throws an error, so catch
% anything here and report it instead.
try
    send(heartbeat);
    if measuredRate(buffer) < 0.8 * wantedHz
        send(rateRequest);
    end
catch err
    fprintf(2, "Heartbeat timer: %s\n", err.message);
end
end

function redraw(buffer, pitchLine, ax)
try
    [t, pitch] = buffer.data();
    if isempty(t)
        return
    end
    % Shift time so the newest sample is at 0 and older ones are negative.
    pitchLine.XData = t - t(end);
    pitchLine.YData = pitch;
    title(ax, sprintf("Pitch %+.1f deg   (ATTITUDE at %.0f Hz)", pitch(end), measuredRate(buffer)))
    drawnow limitrate   % draw now, but no more often than the screen can use
catch err
    fprintf(2, "Redraw timer: %s\n", err.message);
end
end

function shutdown(timers, io, fig)
% Stop the timers first so nothing tries to draw or send after the
% connection and window have gone.
for k = 1:numel(timers)
    if isvalid(timers(k))
        stop(timers(k))
        delete(timers(k))
    end
end
disconnect(io)
if isvalid(fig)
    delete(fig)
end
fprintf("Stopped and disconnected.\n");
end
