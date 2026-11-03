function step2_connect(options)
%STEP2_CONNECT  Milestone 2: connect to a Cube over UDP and print what it sends.
%
%   Listens for the Cube (or tools/fake_cube.py), prints each heartbeat as
%   it arrives and the pitch angle twice a second, then disconnects.
%
%   step2_connect                          % fake_cube.py on this computer
%   step2_connect(LocalPort=14560)         % if port 14550 is taken
%   step2_connect(RemoteHost="192.168.4.1") % a real Cube through its Kahuna
%
%   Name=Value options (like Python keyword arguments):
%     RemoteHost  where the Cube is: "127.0.0.1" for fake_cube.py, "192.168.4.1" for a Kahuna
%     LocalPort   the UDP port we listen on (14550 is what the Kahuna sends to)
%     RemotePort  the UDP port the Cube listens on (14555 on the Kahuna)
%     Duration    how many seconds to run for
%
%   This is a step on the way to CubeGUI, not part of it. It works on
%   R2026a and later: it sends its own heartbeat with a timer instead of
%   using the R2026b heartbeat helper.

% The arguments block checks the inputs and fills in defaults, a bit like
% type hints plus default values in a Python function signature.
arguments
    options.RemoteHost (1,1) string = "127.0.0.1"
    options.LocalPort (1,1) double {mustBeInteger, mustBePositive} = 14550
    options.RemotePort (1,1) double {mustBeInteger, mustBePositive} = 14555
    options.Duration (1,1) double {mustBePositive} = 10
end

% ---- Set up MAVLink ------------------------------------------------------

% The dialect is MATLAB's dictionary of MAVLink messages: names, IDs and
% fields. common.xml has everything we need here.
dialect = mavlinkdialect("common.xml");

% mavlinkio is our end of the link, roughly pymavlink's mavlink_connection.
% System ID 255 and component 190 are the usual ones for a ground station.
io = mavlinkio(dialect, SystemID=255, ComponentID=190);

try
    connect(io, "UDP", LocalPort=options.LocalPort);
catch err
    % The usual reason this fails is that another program, most likely
    % Mission Planner, is already listening on the port. MATLAB's message
    % ends in a long technical part in square brackets, so cut that off.
    shortMessage = strtrim(extractBefore(err.message + " [", " ["));
    fprintf(2, ['Couldn''t listen on UDP port %d.\n' ...
        'Is Mission Planner (or another copy of this script) open? Close it and try again,\n' ...
        'or use a different port, e.g. step2_connect(LocalPort=14560).\n\n' ...
        'MATLAB''s message: %s\n'], options.LocalPort, shortMessage);
    return
end

% The Cube's autopilot is system 1, component 1. Subscribing through this
% client means we ignore messages from anything else on the network, such
% as the Kahuna itself (component 240).
cube = mavlinkclient(io, 1, 1);

% A subscription collects one kind of message. BufferSize=1 keeps only the
% newest. For heartbeats we also give a function to run as each one arrives.
% It's a small standalone function on purpose: a callback that can see this
% function's variables keeps them all alive, and that stopped the cleanup
% below from running when it should (found in testing).
heartbeatSub = mavlinksub(io, cube, "HEARTBEAT", BufferSize=1, ...
    NewMessageFcn=@(~, msg) fprintf("Heartbeat from system %d, component %d\n", ...
    msg.SystemID, msg.ComponentID));
attitudeSub = mavlinksub(io, cube, "ATTITUDE", BufferSize=1);

% ---- Our own heartbeat ----------------------------------------------------

% The Kahuna only sends to us directly once it has heard from us, and goes
% back to broadcasting if we go quiet for 10 s. So we send a heartbeat
% once a second, from a timer, like a background thread in Python.
heartbeat = createmsg(dialect, "HEARTBEAT");
heartbeat.Payload.type(:) = enum2num(dialect, "MAV_TYPE", "MAV_TYPE_GCS");
heartbeat.Payload.autopilot(:) = enum2num(dialect, "MAV_AUTOPILOT", "MAV_AUTOPILOT_INVALID");
heartbeat.Payload.system_status(:) = enum2num(dialect, "MAV_STATE", "MAV_STATE_ACTIVE");
heartbeat.Payload.mavlink_version(:) = 3;
% The (:) above matters: it writes into the existing field and keeps its
% data type (uint8 and so on). Without it the field would become a double.

sendHeartbeat = @(~, ~) sendudpmsg(io, heartbeat, options.RemoteHost, options.RemotePort);
heartbeatTimer = timer(ExecutionMode="fixedRate", Period=1, BusyMode="drop", ...
    TimerFcn=sendHeartbeat, Name="step2_connect heartbeat");

% onCleanup runs the function when this variable disappears: when the
% function ends normally, on an error, or when you press Ctrl+C. It plays
% the part of Python's try/finally, so the timer and port are never left open.
cleanup = onCleanup(@() shutdown(heartbeatTimer, io));

start(heartbeatTimer)

% ---- Print what arrives ----------------------------------------------------

fprintf("Listening on UDP port %d, sending heartbeats to %s:%d, for %g s.\n", ...
    options.LocalPort, options.RemoteHost, options.RemotePort, options.Duration);

lastPitchTime = NaN;
startTime = tic;
warned = false;

while toc(startTime) < options.Duration
    % pause lets MATLAB run the timer and the heartbeat callback. (Python
    % would run those in other threads; MATLAB runs them in the gaps.)
    pause(0.5)

    msgs = latestmsgs(attitudeSub, 1);
    if ~isempty(msgs)
        att = msgs(1).Payload;
        % Only print when the message is new, using the Cube's own clock.
        if att.time_boot_ms ~= lastPitchTime
            lastPitchTime = att.time_boot_ms;
            fprintf("  pitch %+6.1f deg   (Cube time %.2f s)\n", ...
                rad2deg(double(att.pitch)), double(att.time_boot_ms) / 1000);
        end
    end

    heardCube = ~isempty(latestmsgs(heartbeatSub, 1));
    if ~heardCube && toc(startTime) > 3 && ~warned
        warned = true;
        fprintf(2, ['No heartbeat from the Cube yet. Check that:\n' ...
            '  - fake_cube.py is running and sending to port %d, or\n' ...
            '  - this laptop is on the kit''s Wi-Fi (AVDASI2 - Kit X) and the Cube is powered.\n'], ...
            options.LocalPort);
    end
end

fprintf("Done.\n");
end

function shutdown(heartbeatTimer, io)
% Stop and delete the timer first, then close the UDP port.
if isvalid(heartbeatTimer)
    stop(heartbeatTimer)
    delete(heartbeatTimer)
end
disconnect(io)
fprintf("Disconnected.\n");
end
