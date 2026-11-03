function step3_servo(pwm, options)
%STEP3_SERVO  Milestone 3: move one servo with MAV_CMD_DO_SET_SERVO.
%
%   Sends one servo command, clamped to safe limits, waits for the Cube to
%   say whether it accepted it, then checks the output really changed.
%
%   step3_servo(1600)                       % servo 5 to 1600 us, fake_cube.py
%   step3_servo(1600, LocalPort=14560)      % if port 14550 is taken
%   step3_servo(1400, RemoteHost="192.168.4.1")  % a real Cube
%   step3_servo(1700, Servo=6, MinPWM=1200, MaxPWM=1800)
%
%   pwm is a pulse width in microseconds, roughly 1000 to 2000. Anything
%   outside MinPWM..MaxPWM is clamped (pulled back to the nearest limit)
%   before it's sent, and the script says so.
%
%   Remember the safety switch: after every reboot the Cube holds PWM back
%   from the servos until it's toggled off (Mission Planner, Ctrl+F,
%   "Toggle Saftey Switch").

arguments
    pwm (1,1) double {mustBeFinite}
    options.Servo (1,1) double {mustBeInteger, mustBeBetween(options.Servo, 1, 16)} = 5
    options.MinPWM (1,1) double {mustBeFinite} = 1100
    options.MaxPWM (1,1) double {mustBeFinite} = 1900
    options.RemoteHost (1,1) string = "127.0.0.1"
    options.LocalPort (1,1) double {mustBeInteger, mustBePositive} = 14550
    options.RemotePort (1,1) double {mustBeInteger, mustBePositive} = 14555
end

% ---- Clamp first, before anything touches the network ----------------------

if options.MinPWM >= options.MaxPWM
    error("MinPWM (%g) must be less than MaxPWM (%g).", options.MinPWM, options.MaxPWM)
end

safePwm = clampPwm(pwm, options.MinPWM, options.MaxPWM);
if safePwm ~= pwm
    fprintf("Asked for %g us, which is outside %g..%g us: sending %d us instead.\n", ...
        pwm, options.MinPWM, options.MaxPWM, safePwm);
end

% ---- Connect (as in step2_connect) -------------------------------------------

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
cleanup = onCleanup(@() disconnect(io));

cube = mavlinkclient(io, 1, 1);
% BufferSize=10 keeps the last 10 of each, so a reply isn't lost if other
% messages of the same kind arrive while we're busy.
ackSub = mavlinksub(io, cube, "COMMAND_ACK", BufferSize=10);
outputSub = mavlinksub(io, cube, "SERVO_OUTPUT_RAW", BufferSize=1);

% One heartbeat tells the Kahuna where we are. This script is over in a
% couple of seconds, so it doesn't need a timer like step2_connect.
heartbeat = createmsg(dialect, "HEARTBEAT");
heartbeat.Payload.type(:) = enum2num(dialect, "MAV_TYPE", "MAV_TYPE_GCS");
heartbeat.Payload.autopilot(:) = enum2num(dialect, "MAV_AUTOPILOT", "MAV_AUTOPILOT_INVALID");
heartbeat.Payload.mavlink_version(:) = 3;
sendudpmsg(io, heartbeat, options.RemoteHost, options.RemotePort);

% ---- Build and send the command ------------------------------------------------

% COMMAND_LONG is MAVLink's general "do this" message: a command number
% plus seven numbered parameters. For DO_SET_SERVO, param1 is the output
% number (counting from 1, as in SERVO5_FUNCTION) and param2 is the PWM.
cmd = createcmd(dialect, "long", "MAV_CMD_DO_SET_SERVO");
cmd.Payload.target_system(:) = 1;
cmd.Payload.target_component(:) = 1;
cmd.Payload.param1(:) = options.Servo;
cmd.Payload.param2(:) = safePwm;
cmdNumber = double(cmd.Payload.command);

fprintf("Sending servo %d -> %d us to %s:%d\n", options.Servo, safePwm, ...
    options.RemoteHost, options.RemotePort);
sendudpmsg(io, cmd, options.RemoteHost, options.RemotePort);

% ---- Did the Cube accept it? ------------------------------------------------------

ack = waitFor(@() findAck(ackSub, cmdNumber), 2);
if isempty(ack)
    fprintf(2, ['No reply from the Cube within 2 s. Check it''s connected: ' ...
        'try step2_connect first.\n']);
    return
end

resultName = num2enum(dialect, "MAV_RESULT", double(ack.result));
if ack.result == enum2num(dialect, "MAV_RESULT", "MAV_RESULT_ACCEPTED")
    fprintf("Cube accepted the command (%s).\n", resultName);
else
    fprintf(2, ['Cube refused the command (%s).\n' ...
        'The usual reason is that SERVO%d_FUNCTION isn''t 0 (Disabled), so the\n' ...
        'output already belongs to something else. Set it to 0 in Mission Planner.\n'], ...
        resultName, options.Servo);
    return
end

% ---- Did the output change? ----------------------------------------------------------

% SERVO_OUTPUT_RAW reports every output's PWM as fields servo1_raw,
% servo2_raw and so on. Payload.(name) reads a field whose name is in a
% variable, like getattr(payload, name) in Python.
field = sprintf("servo%d_raw", options.Servo);
output = waitFor(@() outputMatches(outputSub, field, safePwm), 2);
if isempty(output)
    fprintf(2, ['The Cube accepted the command, but output %d didn''t show %d us within 2 s.\n' ...
        '(It may be reporting this message slowly: step 4 asks for a faster rate.)\n'], ...
        options.Servo, safePwm);
else
    fprintf("Output %d is now at %d us.\n", options.Servo, output.(field));
    fprintf("If the servo itself didn't move, check the safety switch has been toggled.\n");
end
end

% ---- Local functions ------------------------------------------------------------------

function out = clampPwm(pwm, minPwm, maxPwm)
% Pull pwm back inside minPwm..maxPwm and round to a whole microsecond.
out = round(min(max(pwm, minPwm), maxPwm));
end

function result = waitFor(check, timeout)
% Call check() every 50 ms until it returns something non-empty, or until
% timeout seconds have passed (then return []).
result = [];
startTime = tic;
while isempty(result) && toc(startTime) < timeout
    pause(0.05)   % lets MATLAB receive messages in the meantime
    result = check();
end
end

function ack = findAck(ackSub, cmdNumber)
% The newest COMMAND_ACK for our command, or [] if there isn't one yet.
ack = [];
msgs = latestmsgs(ackSub, 10);
for k = 1:numel(msgs)
    if msgs(k).Payload.command == cmdNumber
        ack = msgs(k).Payload;
        return
    end
end
end

function payload = outputMatches(outputSub, field, pwm)
% The latest SERVO_OUTPUT_RAW, if it shows our output at pwm; otherwise [].
payload = [];
msgs = latestmsgs(outputSub, 1);
if ~isempty(msgs) && msgs(1).Payload.(field) == pwm
    payload = msgs(1).Payload;
end
end
