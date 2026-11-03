# CubeGUI recipes

How to change what CubeGUI shows and does. Most changes are a few lines in the settings file, `config/cubegui.json`, and need no MATLAB at all. For anything new, you copy a short file in the `panels` folder and change the copy.

## Before you start

- **Make your own settings file.** Copy `config/cubegui.json` to, say, `config/team3.json`, and start CubeGUI with `CubeGUI(ConfigFile="config/team3.json")`. When CubeGUI is updated, your file is left alone.
- **Copy, don't edit.** To change a panel, copy it and give the copy a new name, such as `team3ServoPanel.m`. The same goes for the reason above.
- **Leave the `engine` folder alone.** It holds the connection, the logging and the safety rules. Nothing in these recipes needs it. If you change it by mistake, download CubeGUI again, or `git checkout engine` if you cloned it.
- **After editing the settings file, close CubeGUI and start it again.** If something in the file is wrong, CubeGUI won't start, and its message names the entry to fix.

## How the Run tab is put together

The settings file has two lists of **panels**: `plots` (the left-hand side) and `controls` (the right-hand side, under the safety switch). Each entry names a file in the `panels` folder, plus anything that panel needs:

```json
"plots": [
  {"panel": "plotPanel", "signal": "pitch", "height": "2x"},
  {"panel": "plotPanel", "signal": "Elevator"}
],
"controls": [
  {"panel": "servoPanel", "servo": "Elevator"},
  {"panel": "zeroAllButton"},
  {"panel": "valuePanel", "signal": "pitch rate", "level": 1}
]
```

They appear in the order listed. `"level"` is optional: that panel only appears at that capability level and above.

A **signal** is anything with a value that changes over time:

| Signal | What it is | Units |
|---|---|---|
| `"pitch"` | the fuselage's pitch angle, from the Cube | deg |
| `"pitch rate"` | how fast the pitch is changing | deg/s |
| `"rc1"` to `"rc18"` | what the Cube receives on each transmitter channel | µs |
| a servo's name, like `"Elevator"` | where the Cube is driving that servo | the servo's units (µs, or deg once calibrated) |
| any other name, like `"DEMO"` | a value a Lua script sends with `gcs:send_named_float("DEMO", x)` | whatever the script sends |

## Recipe 1: add a plot

Add an entry to `plots`:

```json
{"panel": "plotPanel", "signal": "pitch rate"}
```

Optional entries: `"label"` (what to call it), `"range": [-50, 50]` (the ends of the y-axis), `"height": "2x"` (twice as tall as the others), `"title": true` (show the latest value above it) and `"compare": "CG_TGT"` (a second signal on the same plot, dashed: here the closed loop's pitch target).

## Recipe 2: plot a value from a Lua script

If your script on the Cube sends a value:

```lua
gcs:send_named_float("FLAP_V", voltage)
```

then plot it by its name (up to 10 characters, and case matters):

```json
{"panel": "plotPanel", "signal": "FLAP_V", "label": "Flap sensor (V)"}
```

It also appears in the Setup tab, under "Values from Lua scripts". To log it as well, add its name to `extraSignals` under `logging`:

```json
"logging": {"enabled": true, "folder": "logs", "extraSignals": ["FLAP_V"]}
```

## Recipe 3: show a number in large type

Add an entry to `controls`:

```json
{"panel": "valuePanel", "signal": "pitch", "label": "Pitch (deg)"}
```

## Recipe 4: add a servo

1. Plug the servo into a free output on the Cube, e.g. MAIN OUT 8.
2. In the settings file, add it to `servos`:

   ```json
   {"name": "Flap", "output": 8}
   ```

3. Add a slider for it to `controls`, and a plot to `plots`:

   ```json
   {"panel": "servoPanel", "servo": "Flap"}
   ```

   ```json
   {"panel": "plotPanel", "signal": "Flap"}
   ```

4. Start CubeGUI, connect, and open the **Setup** tab:
   - **`SERVO8_FUNCTION`** must be 0. If it isn't, CubeGUI fills in 0 for you, and **Apply changes...** writes it.
   - **`SERVO8_MIN`, `SERVO8_TRIM` and `SERVO8_MAX`** are the servo's limits, from 1000 to 2000 µs. CubeGUI never sends anything outside MIN to MAX. Set them to suit your mechanism before you connect it to anything.

## Recipe 5: work in degrees instead of PWM

First, calibrate: measure the surface's angle at several PWM values. The **Calibrate** panel (from level 1, for the elevator in the shipped settings) does the stepping for you. Click **Open calibration...**: it opens in a window of its own.

1. Turn the safety switch off, and click **Start**. The servo goes to its `SERVOn_MIN`.
2. Measure the angle, type it in degrees, and click **Record**. The servo moves to the next PWM. Repeat until it says **Finished**: it goes up to `SERVOn_MAX` and back down, so each PWM is measured both ways. The table lists every step, and the plot shows the angles going up and going down. **Back** measures the step before again, also after the end.
3. It shows the hysteresis (the biggest difference between going up and going down), and the settings to paste. Click **Copy settings**.
4. In your settings file, find the servo's `{ }` entry under `"servos"`, and paste the settings in after its `"output"`, with a comma before them. Save, and start CubeGUI again.
5. Check it: set the slider to one or two angles, and measure them.

What the result means for your tests:

- **The slider now works in degrees**, using straight lines between your measured points. CubeGUI still never sends anything outside `SERVOn_MIN` to `SERVOn_MAX`.
- **Hysteresis** is how far the angle can differ depending on which way the surface last moved (slack in the linkage, mostly). If it's large compared with the accuracy you need, approach each test angle from the same side, and say so in your method.
- **Calibrate again** after any change to the linkage, the servo horn or the limits.
- **Under air load** the angle may differ from this unloaded calibration. Measuring that needs a sensor on the hinge (see the guide's ADC and I²C pages).

To calibrate another servo, add another panel: `{"panel": "calibrationPanel", "servo": "Rudder", "steps": 9}`.

Then give the servo the calibration table in the settings file, and its slider works in degrees:

```json
{"name": "Elevator", "output": 5, "units": "deg",
 "mapping": {"type": "table", "points": [[-20, 1150], [0, 1500], [20, 1870]]}}
```

Each point is `[angle, pwm]`. See [config/README.md](../config/README.md) for the other kinds of mapping (linear, exponential, a formula).

## Recipe 6: make a button

Copy `panels/zeroAllButton.m` to a new file, e.g. `panels/sweepButton.m`. Change the name on its first line to match the file name. Then change what the button does. This one moves the elevator to 1600 µs, waits a second, then moves it back to its trim position:

```matlab
function panel = sweepButton(parent, cube, options)
%SWEEPBUTTON  Moves the elevator up, then back to the middle.

uibutton(parent, Text="Elevator up and back", ...
    ButtonPushedFcn=@(~, ~) upAndBack(cube));

panel.height = 36;   % in pixels
end

function upAndBack(cube)
cube.moveServo("Elevator", 1600);
pause(1)
elevator = cube.servo("Elevator");
cube.moveServo("Elevator", elevator.trim);   % SERVOn_TRIM, in the slider's units
end
```

Add it to `controls`:

```json
{"panel": "sweepButton"}
```

## Recipe 7: make a panel that keeps itself up to date

A panel can hand back an `update` function, which CubeGUI runs 10 times a second. This one shows whether the landing gear is stowed, moving or deployed.

The Cube reports the PWM it's sending, not where the servo has actually got to, so "moving" is worked out from how long the gear takes to move. Time it on the rig and put it in the settings.

```matlab
function panel = gearStatusPanel(parent, cube, options)
%GEARSTATUSPANEL  Shows whether the landing gear is stowed, moving or deployed.
%
%   In config/cubegui.json, under "controls":
%       {"panel": "gearStatusPanel", "servo": "Gear", "seconds": 3}
%
%   "seconds" is how long the gear takes to move: time it on the rig.

name = string(options.servo);
travelSeconds = options.seconds;

% ---- Build the panel (runs once, when the window opens) ------------------
box = uipanel(parent, Title=name + " status");
grid = uigridlayout(box, [1 2], ColumnWidth={24, "1x"});
lamp = uilamp(grid, Color=[0.6 0.6 0.6]);
words = uilabel(grid, Text="Not moved yet", FontSize=16);

% ---- Hand back what the window needs -------------------------------------
panel.height = 60;
panel.update = @() showStatus(cube, name, travelSeconds, lamp, words);
end

function showStatus(cube, name, travelSeconds, lamp, words)
% Runs 10 times a second.
target = cube.servoTarget(name);   % where it was last asked to go, in its units (µs)
s = cube.servo(name);
trim = s.trim;                     % its SERVOn_TRIM, in the same units

% Remember when the target last changed. Every part of a window has a
% UserData property, for remembering things like this between updates.
if isempty(lamp.UserData) || ~isequaln(lamp.UserData.target, target)
    lamp.UserData = struct("target", target, "since", tic);
end

if isnan(target)
    words.Text = "Not moved yet";
    lamp.Color = [0.6 0.6 0.6];        % grey
elseif toc(lamp.UserData.since) < travelSeconds
    words.Text = "Moving";
    lamp.Color = [1 0.7 0];            % amber
elseif target > trim
    words.Text = "Deployed";
    lamp.Color = [0 0.75 0];           % green
else
    words.Text = "Stowed";
    lamp.Color = [0 0.4 1];            % blue
end
end
```

```json
{"panel": "gearStatusPanel", "servo": "Gear", "seconds": 3}
```

## What a panel can ask the Cube

Every panel is given `cube`. These are everything it offers, and all of them are safe to call as often as you like:

| Call | What it does |
|---|---|
| `cube.moveServo("Elevator", 1600)` | Moves a servo, in its own units (µs, or deg once calibrated). CubeGUI turns that into PWM, keeps it within the servo's limits, and sends at most 10 commands a second. |
| `cube.moveServoPwm("Elevator", 1600)` | The same, but always in µs, even once the slider is in degrees, e.g. for calibrating. Still kept within the servo's limits. |
| `cube.zeroAll()` | Sends every servo to its trim position. |
| `cube.latest("pitch")` | The newest value of a signal, or `NaN` if there isn't one. |
| `[t, y] = cube.history("pitch")` | The last 30 s or so of a signal. `t` is in seconds, 0 being now. |
| `cube.units("pitch")` | A signal's units, e.g. `"deg"`. |
| `s = cube.servo("Elevator")` | A servo's details: `s.output`, `s.units`, `s.range`, `s.trim` (its trim position, in its units), `s.ready` (true once it can be moved), `s.why` (why not, if not), `s.minPwm`, `s.trimPwm`, `s.maxPwm`. |
| `cube.servoTarget("Elevator")` | The last position anything asked for, in its units. |
| `cube.servoSent("Elevator")` | The last position actually sent to the Cube, in its units. |
| `cube.servoNames()` | Every servo's name, from the settings. |
| `cube.isConnected()` | True while connected. |
| `cube.say("text")` | Shows a message in the status line. `cube.say("text", true)` shows it in red. |
| `cube.mark("run 3")` | Puts a run marker in CubeGUI's log and the Cube's own log. |
| `m = cube.mode()` | From level 2: who's in charge. `m.name` is `"CubeGUI"`, `"Transmitter (RC)"` or `"Closed loop"`; also `m.script`, `m.rc`, `m.sas` and `m.target`. |
| `cube.requestMode("closed loop")` | From level 3: hand the elevator to the closed loop (`"gui"` takes it back). A transmitter switch can overrule it. |
| `cube.setPitchTarget(5)`, `cube.setSas(true)` | The closed loop's pitch target in degrees, and stability augmentation on or off. |
| `cube.PlotSeconds`, `cube.Level` | How long the plots are, and the capability level. |

Nothing on `cube` arms the Cube, writes its parameters or changes its safety switch. Those stay in the parts of the window that ask first.

## Every panel follows the same pattern

```matlab
function panel = myPanel(parent, cube, options)
% Build the controls inside parent (runs once, when the window opens).
% options is your { } block from the settings file.
...
panel.height = 100;                    % pixels (controls), or "2x" (plots)
panel.update = @() showLatest(...);    % optional: run 10 times a second
end
```

MATLAB's documentation for each `ui...` function (`uibutton`, `uislider`, `uilabel`, `uilamp`, `uiaxes`...) has pictures and examples. Type `doc uibutton` in the Command Window.

## When something goes wrong

If a panel has a mistake in it, CubeGUI shows a red message in its place, naming the file and the line, for example:

> sweepButton.m didn't open: Unrecognized function or variable 'cub'. (sweepButton.m, line 4)

The rest of the window carries on working. The same message appears in the Command Window. Fix the line, close CubeGUI and start it again.
