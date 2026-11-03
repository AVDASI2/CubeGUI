# How CubeGUI works

A plain description of each part of CubeGUI and how the parts connect, written from the code as it stands. It's kept up to date as the code changes. Design decisions and their reasons are in [requirements.md](requirements.md) (sections 4 and 5) and, from now on, [decisions.md](decisions.md).

Last checked against the code: 2026-11-03, after the levels were renumbered 0–3, sliders became PWM, and the Logs panel, log download, gains box and script install were added (not yet committed).

## The big picture

CubeGUI does four jobs at once: it listens to the Cube, draws what it hears, sends servo commands, and writes a log. MATLAB runs all of them on **one thread**, so nothing truly happens in parallel. Instead, small pieces of code take turns:

- **Message callbacks** run when a MAVLink message arrives. They only store the data.
- **Timers** run on a schedule: one redraws the window, one writes the log, one sends CubeGUI's heartbeat.
- **Button and slider callbacks** run when someone clicks or drags.

Everything they share lives in one object, `Telemetry`. Callbacks put data in; the timers take it out.

```text
 Cube ─MAVLink/UDP─► CubeSource ─stores─► Telemetry (ring buffers, params, safety, version)
                         ▲                     │
 SimulatedSource ────────┘ (same interface)    ├─► CubeGuiApp redraw timer (10 Hz) ─► each panel's update ─► cube.latest / cube.history
                                               └─► CsvLogger timer (2 Hz) ─► logs/*.csv
 a panel's slider ─► cube.moveServo ─► ServoMapping (units→PWM), 10 a second ─► DataSource.setServo (clamps) ─► sendServo
```

The code is in two folders:

- **`engine/`**: the connection, `Telemetry`, logging, the safety rules, and the window's frame (connection bar, safety switch, Setup tab, status line). Students aren't expected to change it.
- **`panels/`**: one short function file per plot, slider, readout or button on the Run tab. The settings file lists which appear. Students copy and change these.

The two meet in one object, `cube` (`engine/Cube.m`). It's the only thing a panel is given, and everything on it is safe to call: see "Panels and the cube object" below.

In Python terms it's close to an event loop (like `asyncio` or a Tkinter `mainloop`): short callbacks, a shared state object, and periodic tasks. The one rule that makes it work is that **no callback does slow work**. Drawing a plot is slow, so callbacks never draw.

## What happens when you type `CubeGUI`

1. `CubeGUI.m` adds the `engine` and `panels` folders to MATLAB's path (like adding to `sys.path`), so MATLAB can find the code. `CubeGUI(Level=1)` overrides the level in the settings, and `CubeGUI(Demo=true)` adds a level drop-down.
2. `loadConfig` reads `config/cubegui.json` and checks every entry. A bad entry stops CubeGUI with a message naming it. It also:
   - checks each servo's `mapping` (with ArduPilot's default limits, since the Cube's aren't known yet);
   - turns `plots` and `controls` into a list of panels, each with a name, a level, and its `{ }` block as options. Without those lists it makes the default ones (a pitch plot, a plot and a slider per servo, Zero all).
3. `CubeGuiApp(config)` creates:
   - a `Telemetry` store, sized for the plot window;
   - a `CsvLogger` (not yet writing);
   - the `cube` object;
   - the Setup tab's parameter list, from `setupParameters`, for this level.

   It then builds the window, calling each panel's function in turn (see below), and starts the **redraw timer**, 10 times a second.
4. Nothing talks to a Cube yet. The window shows "Choose a source and click Connect."

## What happens when you click Connect

`CubeGuiApp.connect`:

1. Clears `Telemetry`, so nothing from a previous connection is left over.
2. Makes a data source: `SimulatedSource` or `CubeSource`, whichever the drop-down says.
3. Calls `source.connect()`. If that fails (port in use, no UAV Toolbox), the error goes in the status line and a pop-up.
4. Asks the source for every parameter in the Setup tab, plus each servo's `SERVOn_MIN`, `_TRIM` and `_MAX`, which CubeGUI needs at every level.
5. Hands the source to `cube.attach`. The servos switch on as their limits arrive (see "Data going out").
6. Starts the logger, if the level is 1 or more and `logging.enabled` is true (or the Logs panel's **Start** was last used to start it).

### `CubeSource.connect`, the real Cube

1. Loads MATLAB's MAVLink message dictionary (`mavlinkdialect("common.xml")`) and opens a UDP port (`mavlinkio`, then `connect(..., "UDP", LocalPort=...)`). CubeGUI calls itself system 255, component 190, the usual numbers for a ground station. If the port is taken (usually by Mission Planner), `isPortInUse` spots it from the error's text or the operating system's error number, and the message says what to do.
2. Subscribes (`mavlinksub`) to eight messages from the Cube's autopilot only (system 1, component 1). That filter is what ignores the Kahuna's own messages (component 240). Each subscription has a **callback**, a one-line anonymous function (like a Python `lambda`) that unpacks the message and calls one `Telemetry.add...` method:

   | Message | Callback stores |
   |---|---|
   | `HEARTBEAT` | the time it arrived, and the vehicle type |
   | `ATTITUDE` | pitch in degrees, against the Cube's clock |
   | `SERVO_OUTPUT_RAW` | the PWM on all 16 outputs, against the Cube's clock |
   | `COMMAND_ACK` | the Cube's reply to a command: which command, and the result |
   | `PARAM_VALUE` | a parameter's name and value |
   | `AUTOPILOT_VERSION` | firmware version, git hash, board and unique ID |
   | `SYS_STATUS` | the safety switch state (see below) |
   | `NAMED_VALUE_FLOAT` | a value sent by a Lua script, by name |

   Every subscription holds up to 200 messages (`BufferSize`). With MATLAB's default of 1, messages that arrive while MATLAB is busy are thrown away.
3. Builds the messages it will send over and over: its own `HEARTBEAT`, three `SET_MESSAGE_INTERVAL` rate requests, a `DO_SET_SERVO` template and a `REQUEST_MESSAGE` for the version.
4. Starts its **once-a-second timer** (`everySecond`), which:
   - sends CubeGUI's heartbeat. The Kahuna only sends to a laptop it has heard from in the last 10 s, so this keeps the data coming;
   - re-sends any rate request whose message is arriving at under 80 % of the rate asked for. This is also how CubeGUI recovers after the Cube reboots and forgets the rates;
   - re-sends a safety switch request that hasn't taken effect yet;
   - once the Cube is answering, asks for the version until it arrives, and re-asks for any missing parameters (for up to 10 s).

### `SimulatedSource.connect`, no hardware

A 20 Hz timer calls `step()`, which does what a Cube would: adds a heartbeat once a second, a pitch sample (a sine wave, plus noise, plus a nudge from the elevator), and the output PWMs. It also pretends to have a parameter list, a safety switch that starts on, and a Lua value called `DEMO`. It needs no toolbox, so it runs in MATLAB Online.

## Data coming in: `Telemetry` and `RingBuffer`

`Telemetry` is the shared store. It holds:

- three **ring buffers**: pitch (each sample holds pitch, the laptop's clock on arrival, and pitch rate), outputs, and commands sent. A `RingBuffer` is a fixed-size array that overwrites its oldest entry when full, like Python's `collections.deque(maxlen=n)`. Memory use never grows, however long CubeGUI runs;
- a ring buffer for each Lua value, made the first time that name arrives (`addNamedValue`, `namedHistory`), so Lua values can be plotted like pitch;
- the latest heartbeat time and count, the last command reply, the vehicle type;
- the parameters, and the Lua values, each in a `dictionary` (MATLAB's equivalent of a Python `dict`);
- the version, and the safety switch state (`true`, `false`, or `NaN` for "not known yet").

Some details matter for long tunnel runs and patchy Wi-Fi:

- **Times are the Cube's own clock** (seconds since it booted), not the laptop's, so plots are as smooth as the Cube's sampling whatever the Wi-Fi does. Each pitch sample also records the laptop's clock when it arrived, for the log.
- **Samples can arrive late and out of order** over Wi-Fi. A sample older than the newest one held is skipped (and counted in `LateCount`), so the buffers always run in time order.
- **A Cube reboot** also shows up as its clock going backwards. `addPitch` calls it a reboot only if the clock is more than a second back and either under a minute (the Cube has just started) or samples have kept arriving behind for 3 s. Then `Telemetry` empties both buffers, so the plot doesn't draw a line back to the old data, adds one to `RebootCount`, and forgets the version so it's asked for again.
- **`SERVO_OUTPUT_RAW`'s microsecond clock wraps** back to zero every 71.6 minutes. `addOutputsUsec` works out how many times it has wrapped from the pitch clock (milliseconds, which doesn't wrap for 49 days), so the two line up even when the Cube had been on for hours before CubeGUI connected.

`Telemetry` and `RingBuffer` are **handle classes** (`< handle`). Every variable holding one points at the same object, as with any Python object. MATLAB's default is the opposite: a plain value is copied when it's passed to a function. Without `< handle`, each callback would be adding samples to its own private copy.

### The safety switch state

ArduPilot doesn't send the safety switch state directly. It does mark "motor outputs" (bit 32768) as enabled in `SYS_STATUS` whenever the switch is off, so `addSysStatus` reads that bit. CubeGUI asks for `SYS_STATUS` twice a second. (Checked in ArduPilot's `GCS.cpp`.)

## Drawing: the redraw timer

`CubeGuiApp.redraw` runs 10 times a second. It only reads `Telemetry` and updates the window:

1. **Lamp:** green if a heartbeat arrived in the last 2 s; amber "Waiting for the Cube..." for the first 3 s; otherwise red, with a hint about Wi-Fi and ports if nothing was ever heard.
2. **`cube.tick`:** checks for new servo limits, and sends any servo command the rate limit held back.
3. **Panels:** calls every panel's `update` function. A panel that errors is switched off, and its space shows the error in red (see below).
4. **Log label:** the file name and row count.
5. **Safety panel:** lamp, text and button label, and whether a request to change it has worked (or given up after 5 s).
6. **Command replies:** if the Cube refused a `DO_SET_SERVO`, the status line says the output's `SERVOn_FUNCTION` probably isn't 0.
7. **Parameter writes:** see the Setup tab below.
8. **Reboots:** if `Telemetry.RebootCount` has gone up, the status line says the Cube restarted and its safety switch is on again, and the Setup tab's parameters are read again.
9. **Setup tab:** only once a second, and only while it's showing, because updating a `uitable` is slow.

Then `drawnow limitrate` pushes the changes to the screen, at most about 20 times a second.

The plots have MATLAB's click-and-drag interactions switched off (`disableDefaultInteractivity` in `plotPanel`). MATLAB otherwise sets them up the first time a plot draws data, which held everything up for over 2 s just after connecting.

Every timer function is wrapped in `try`/`catch`, because a MATLAB timer whose function throws an error stops for good. The redraw prints any error in the Command Window with the function and line it came from.

## Panels and the cube object

A **panel** is a function in the `panels` folder with this shape:

```matlab
function panel = servoPanel(parent, cube, options)
    % build the controls inside parent, once
    panel.height = 150;                   % pixels, or "2x" for a plot
    panel.update = @() showLatest(...);   % optional: run 10 times a second
end
```

- `parent` is the space the window has set aside for it.
- `cube` is the `Cube` object.
- `options` is the panel's own `{ }` block from the settings file, e.g. `options.servo` is `"Elevator"`.

`CubeGuiApp.addPanel` calls each one with `feval(name, holder, cube, options)` (like calling a function by its name in Python with `globals()[name](...)`). It sets the row's height from `panel.height` and keeps `panel.update` for the redraw timer.

Inside a panel, its controls' callbacks and its `update` are one-line anonymous functions (`@(...)`) that call local functions further down the same file, passing in what they need. They capture only what they use (the `cube`, some controls), never a whole workspace, which keeps rule 3 of the brief.

**A panel can't break the window.** If calling it throws an error, `addPanel` puts a red message in its place, with the file and line (`panelLine` finds the line in the panel's own file, not deep inside MATLAB). If its `update` throws, `updatePanels` switches it off and does the same. Either way the message is also printed in the Command Window, and everything else carries on.

The shipped panels: `plotPanel` (any signal), `servoPanel` (a slider for one servo), `valuePanel` (a big number) and `zeroAllButton` (the simplest, for copying). `docs/recipes.md` is the students' guide to them, with examples.

**`cube`** (`engine/Cube.m`) answers questions about **signals** and moves **servos**:

- A signal is a name: `"pitch"` and `"pitch rate"` (from `Telemetry.Pitch`), a servo's name (the PWM the Cube reports, from `Telemetry.Outputs`, converted to the servo's units, with 0, meaning no pulses, left as a gap), or anything else, taken as the name of a Lua value (`Telemetry.namedHistory`). `cube.history(signal)` gives the last `PlotSeconds` with 0 as now; `cube.latest(signal)` the newest value.
- `cube.servo(name)` gives a servo's details as a struct: output, units, range, whether it's ready, and its limits.
- `attach`, `detach`, `tick` and `sendNow` are `Hidden`: the window and the tests call them, and they don't show up for students in tab completion.

## Data going out: moving a servo

1. A panel calls `cube.moveServo("Elevator", value)`, in the servo's own units: PWM in µs by default, or degrees once calibrated. `servoPanel` does this as the slider is dragged, when it's let go, and when a number is typed.
2. **The servo must be ready.** `Cube.updateLimits` (called from `attach` and every `tick`, but only doing anything when a parameter has arrived) reads the Cube's `SERVOn_MIN`, `_TRIM` and `_MAX`. Usable limits go to `DataSource.setServoLimits`, and the servo's `ServoMapping` is rebuilt from them (PWM: the slider runs from MIN to MAX; percent: 0 % is TRIM, ±100 % is MAX or MIN). Because a PWM slider's ends are the Cube's limits, `servoPanel` and `plotPanel` check `cube.servo(name).range` as they update and follow it when it changes; `servoPanel` then starts its slider at `cube.servo(name).trim`. Limits outside 1000–2000 µs, or not MIN < TRIM < MAX, switch that servo off, with a message saying which parameter to fix. `servoPanel` greys its slider out while the servo isn't ready.
3. **At most 10 commands a second per servo.** If `moveServo` comes less than 0.1 s after the last send, the value is kept as `pending`, and `tick` sends it 0.1 s after the last one. So dragging never floods the Wi-Fi, and the final position is never lost. Having this in the engine means a student's own slider or loop can't flood it either.
4. `ServoMapping.toPwm` turns the value into PWM. The mapping comes from the settings: PWM (the default), percent, a calibration table (straight lines between points), linear, exponential, or a custom formula. A custom formula may only use `x`, numbers, arithmetic and a few maths functions, so a settings file can't run arbitrary MATLAB. Every mapping must always go up or always go down across its range.
5. **`DataSource.setServo` is the safety net.** It refuses outputs with no limits, clamps the PWM to the servo's `SERVOn_MIN`..`SERVOn_MAX`, rounds it, sends it, and records it in `Telemetry.Commands` for the log. The sources' own `sendServo` methods are `protected` (like a Python method starting with `_`, but enforced), so no other code can get round the clamp. The Cube doesn't clamp `DO_SET_SERVO` itself (on a function-0 output it ignores `SERVOn_MIN/MAX`), so this is the only clamp.
6. `CubeSource.sendServo` fills in the `DO_SET_SERVO` template (output number, PWM) and sends it with `sendudpmsg`.
7. The Cube's `SERVO_OUTPUT_RAW` then shows the output changing, which is what a servo's plot shows (solid). It's the PWM the Cube is *sending*, not where the servo has physically got to.

**Zero all** (`cube.zeroAll`) sends every ready servo exactly its `SERVOn_TRIM`, and says if any were skipped.

`servoPanel` keeps itself in step with commands from elsewhere: if `cube.servoTarget` (the last position anyone asked for) differs from its box, as after Zero all, it moves its slider and box to match.

## Levels

`engine/levels.m` lists the four capability levels, 0 to 3: Simulate, Connect and log, RC, Closed loop. (Until 3 November there were six, 1 to 6: see `decisions.md`.) The level comes from `"level"` in the settings (or `CubeGUI(Level=n)`), and decides:

- what the engine shows: level 0 offers only the Simulated source and hides the Setup tab (by unparenting it, so it still works but isn't shown); logging, the Logs panel and the Lua values panel start at level 1; the script install box at level 2; the gains box at level 3;
- which panels appear: each panel entry can have its own `"level"` (0 if it has none);
- which parameters the Setup tab lists: each entry in `setupParameters` has a level. Level 1 has what driving servos needs, and logging and Lua; level 2 adds safety-mask and arming parameters, and the script's; level 3 the gains.

The tunnel profiles (`config/fuselage.json` and the wings) are settings files at level 3, not a level of their own.

Each level also has `released`. Levels 2 and 3 are false for now: they work, but aren't released to students. At such a level the window's title ends "(preview: not released yet)", the status line says so in red when the window opens, and the demo drop-down marks them "(preview)". Releasing a level means setting it to true.

The window's title shows the level. `CubeGUI(Demo=true)` adds a drop-down that closes the window and opens it again at the chosen level (`changeLevel`). Levels hide features; they don't lock them.

## Levels 2 and 3: RC and the closed loop

From level 2, a Lua script on the Cube, `lua/cubegui.lua`, can drive servos instead of CubeGUI. Every servo stays on `SERVOn_FUNCTION = 0` throughout, so changing mode never changes the Cube's set-up. `lua/README.md` is the students' guide; `decisions.md` has the design decisions and what was checked in ArduPilot.

**On the Cube.** The script runs 50 times a second. It decides the mode:

- **0, CubeGUI:** it does nothing.
- **1, RC:** it copies sticks onto outputs.
- **2, closed loop:** a PID moves the elevator to hold a pitch target.

A transmitter switch decides if there is one: the channel with `RCn_OPTION = 300` (`CGUI_MODE_FUNC`), low RC, high CubeGUI, middle no change. Otherwise CubeGUI does. SAS works the same way with 301. It drives an output with `SRV_Channels:set_output_pwm_chan_timeout`, renewed every run and lapsing after 0.1 s. While that override is active, ArduPilot ignores `DO_SET_SERVO` for that output (`SRV_Channel.cpp`), so only one thing drives a servo at a time, and if the script stops, its hold lapses within 0.1 s. It keeps outputs within `SERVOn_MIN/MAX` and honours `SERVOn_REVERSED`. Five times a second it sends `CG_MODE`, `CG_SAS`, `CG_TGT`, `CG_RC` and `CG_ELEV` as named values, and 10 times a second it writes a `CGUI` entry to the Cube's own log.

**CubeGUI to the script.** `Cube.requestMode`, `setPitchTarget` and `setSas` store a request; `Cube.sendRequest` sends it as a `COMMAND_LONG` with `MAV_CMD_USER_1` (31010): param1 mode, param2 target, param3 SAS. `DataSource.sendScriptCommand` does the sending, so the Simulated source can answer too. The request is resent once a second (`tick`), so a lost message is soon made good, and target changes from a slider are sent at most 10 times a second. The script decodes the message with `string.unpack`, so no MAVLink module files are needed on the SD card.

**Who's in charge.** `Cube.mode()` reads `CG_MODE` and the rest. The script counts as absent if `CG_MODE` hasn't arrived for 2 s (`Telemetry.secondsSinceNamed`). `Cube.usable(k)` combines a servo's limits with `scriptDrives(output)`: in closed loop the elevator output (`CGUI_ELEV_OUT`), and in RC mode the outputs in `CGUI_Mn_OUT`. `cube.servo(name).ready` is false while the script drives it, with the reason in `why`, so `servoPanel` greys out with an explanation. When the script hands a servo back, `followScript` moves its target to where the servo actually is, so the slider catches up rather than the servo jumping.

**The transmitter.** `RC_CHANNELS` is read 5 times a second into `Telemetry.Rc`. Its channels are signals `rc1` to `rc18`, shown by `rcPanel`. From level 2 the Setup tab wants `THR_FAILSAFE = 2`: with 0, ArduPlane never declares RC lost, so the script would keep using the last stick positions.

**The Simulated source** acts as if the script were installed, once CubeGUI has sent it a command (which `Cube.attach` does from level 2). In `runScript` it runs the same PID with its own `CGUI_` parameters (gains tuned for the simulation), ignores CubeGUI's commands to the elevator during closed loop, and reports the same named values. It has no transmitter, so there's no RC mode in the simulation.

**Below level 2** the window has no mode controls, so `Cube.tick` watches for the script reporting closed loop and, if it does, asks for CubeGUI mode once a second. That stops a Cube left in closed loop by a higher level keeping the elevator from a level 1 window.

**The gains box** (level 3, built by `CubeGuiApp.buildGainsPanel`) shows `CGUI_KP`, `CGUI_KI` and `CGUI_KD` as the Cube reports them. A box someone has typed in stops following the Cube until the Cube has that value. **Apply...** lists the changed gains and writes them through the same `confirmed`/`writeParams` path as the Setup tab. It's in the engine rather than a panel because panels can't write parameters.

**Installing the script** (level 2, the Setup tab's **cubegui.lua on the Cube** box). `engine/FtpUpload.m` copies `lua/cubegui.lua` with MAVLink's file transfer protocol: `ResetSessions`, `CreateFile` with the path, `WriteFile` 239 bytes at a time, `TerminateSession`, each one a `FILE_TRANSFER_PROTOCOL` message answered by an ACK or NAK. Like `LogDownload`, it only hands back payloads; `CubeSource.sendFtp` sends them and its subscription feeds the answers back with `addReply`. A request with no answer after 1 s is re-sent with the same sequence number, which ArduPilot answers with its last reply (`GCS_FTP.cpp`). Then `CubeSource.restartScripts` sends `MAV_CMD_SCRIPTING` (42701) with 3, stop and restart. The folder is `CubeSource.ScriptFolder`: `/APM/scripts` on a Cube, `scripts` in SITL. UAV Toolbox's own `ftpMicroservice` is R2026b-only, so it isn't used.

**Panels.** `modePanel` shows who's in charge; from level 3 it adds buttons, a pitch-target slider and SAS. `rcPanel` shows the transmitter's channels. `plotPanel` can draw a second signal dashed (`"compare": "CG_TGT"` on the pitch plot).

## Markers, extra signals and the tunnel profiles

- **Run markers:** `cube.mark(text)` (from `markerPanel`) stores a marker in `Telemetry.Markers` and sends it as `STATUSTEXT` (`CubeSource.sendText`), which ArduPilot writes into its own log as `MSG`. `CsvLogger` puts it in the `marker` column of the row at the Cube time it was made (using the same clock-difference estimate as commands), quoted.
- **Extra logged signals:** `logging.extraSignals` in the settings lists Lua values to log. `CsvLogger` adds a column for each, with its latest value at or before the row's Cube time, from `Telemetry.namedHistory`.
- **Profiles:** `config/fuselage.json`, `portwing.json` and `starboardwing.json` are settings files for each tunnel test. The wing ones are placeholders until the teams say which outputs and sensors they use.
- `docs/flight-log.md` covers the Cube's own `.bin` log, and lining it up with CubeGUI's.

## USB and firmware (level 1)

**Connecting over USB.** From level 1 the Source drop-down has **Cube (Wi-Fi)** and **Cube (USB)**; on MATLAB before R2026b only **Cube (Wi-Fi)**, since UAV Toolbox does MAVLink over a serial port only from R2026b. Then "Cube address" becomes "USB port", a drop-down of the computer's serial ports (`usbPorts` in `CubeGuiApp.m`, lowest-numbered first). Each system names a USB serial device like the Cube its own way, whatever hub or dongle it's on: `/dev/cu.usbmodem...` on a Mac, `/dev/ttyACM...` on Linux, `COMn` on Windows. So on a Mac and Linux only those are listed, which leaves out Bluetooth speakers and headphones (a Mac gives each one a serial port named after it, such as `/dev/cu.JBLCharge5`); Windows names give no clue, so every COM port is listed. Choosing **Cube (USB)** labels the ports (`labelUsbPorts`). A Cube's USB cable carries two serial ports: the first is MAVLink and the second SLCAN, a CAN-bus link (ArduPilot's hwdef: `OTG1`, `OTG2`); a USB-C dongle can add one of its own. `CubeSource.findMavlink` opens them all with UAV Toolbox, as the connection does, listens for 1.5 s without sending anything, and marks a port MAVLink if a MAVLink system other than CubeGUI was heard on it; that one is chosen. If none is heard, the lowest-numbered port that isn't in use is marked "probably MAVLink", which is the usual way round. Ports another program has open are listed too, as "(in use)", and the status line asks whether another CubeGUI window or Mission Planner is open: `serialportlist("available")` would leave them out, and with a second CubeGUI window holding the MAVLink port, the other port was guessed instead (Robin, 4 November). It doesn't use MATLAB's `serialport` to listen: on a Mac with a real Cube, `serialport` heard nothing until something had been written to the port, while `mavlinkio` heard a heartbeat within 0.1 s of opening it, every time (tested 4 Nov 2026). `CubeSource` takes the port as a sixth argument. `connect` then calls `connectSerial` instead of `connectUdp`: UAV Toolbox's `connect(io, "Serial", SerialPort=..., BaudRate=115200)`, which only exists from R2026b, so on R2026a it stops with a message (though the drop-down doesn't offer USB there). Everything after that is shared (`subscribe`), and `send` uses `sendserialmsg` instead of `sendudpmsg`.

**A reboot over USB.** When the Cube reboots, its USB device disappears for a few seconds and comes back on the same port name, and the old connection hears nothing more from it: Robin found CubeGUI had to be disconnected and connected again. So `CubeSource.everySecond`, when it has heard no heartbeat for 3 s over USB, waits for the port to be listed again and then reopens it (`reopenSerial`: a new `mavlinkio`, connected again, and the subscriptions made again), at most every 3 s. While the port is gone it sends nothing, so no errors pile up. Over the Wi-Fi none of this is needed: the Kahuna stays up while the Cube reboots, and the messages simply start again. Tested on SITL through `tools/sitl/usb_relay.py`, which gives SITL a pseudo serial port, and on a real Cube Orange+ on a Mac (4 Nov 2026: labelling, connecting, parameters, 20 Hz pitch, the log list, and a log download at about 280 kB/s).

**Flashing firmware** (the Setup tab's **Firmware over USB** box, `flashPressed` and the methods after it):

1. Choose the firmware: the latest stable ArduPlane (downloaded once the board is known), or an `.abin` file.
2. Get the Cube into its bootloader. If it's connected, `CubeSource.reboot(true)` sends `MAV_CMD_PREFLIGHT_REBOOT_SHUTDOWN` with param1 = 3, "restart and stay in the bootloader", and CubeGUI disconnects. If not, the student unplugs and replugs the cable: the bootloader waits 5 s after power-up (`HAL_BOOTLOADER_TIMEOUT`).
3. `findBootloader` tries each USB port for up to 30 s, with a FirmwareUpload and one sync attempt each. The bootloader may come up on a different port name from ArduPilot's.
4. `FirmwareUpload.identify` asks the bootloader's protocol version, the board's ID and the flash size. Once it has had a sync and those answers, the bootloader stops its timer and waits (`bl_protocol.cpp`). So downloading the firmware for that board (`https://firmware.ardupilot.org/Plane/stable/<board>/arduplane.abin`) can happen then. Only the kits' two boards are known: 140 Cube Orange, 1063 Cube Orange+.
5. After a confirmation, `FirmwareUpload.flash` erases, writes 252 bytes at a time, compares the bootloader's CRC of the whole flash with its own, and reboots the Cube. The erase can't report how far it has got, so the progress dialog shows "busy" with the seconds so far (progress fraction NaN); a Cube Orange+ took about 30 s, and up to 90 s is allowed.

**Flashing keeps the Cube's parameters** (the bootloader only erases the firmware), and the SD card's scripts. **Reset to a fresh Cube** (`resetPressed`) is what gives a clean start. It writes `FORMAT_VERSION` = 0 and reboots once that's confirmed (`RebootAfter`). As ArduPilot starts, the wrong format version makes it erase all its stored settings (`AP_Vehicle/Parameters.cpp`, `load_parameters`). That's also why the guide's "flash Sub, then Plane" works. Scripts stay on the SD card but don't run, because `SCR_ENABLE` is back to 0. The telemetry defaults (MAVLink2 at 57600) suit the Kahuna, so this works over the Wi-Fi too. The Simulated source copies it: `FORMAT_VERSION` 0 and a reboot put its parameters back to their defaults.

The protocol is ArduPilot's `Tools/scripts/uploader.py`, ported. The CRC is CRC-32 starting from 0 with no final inversion; on the real ArduPlane file it matched `uploader.py`'s exactly. CubeGUI uses `.abin` files, which hold the firmware image uncompressed, because MATLAB R2026 has no Java and so no built-in way to unpack the zlib-compressed image inside an `.apj`. The flashing runs in a button's callback, with a progress dialog, rather than in a timer: it's over in a minute or so, and nothing else needs the connection meanwhile. A failed flash leaves the bootloader alone, so flashing again recovers it. Tested against `tests/FakeBootloader.m`, a pretend bootloader with its own bit-by-bit CRC; not yet on a real Cube.

## Calibration

`calibrationPanel` (level 1) is a button on the Run tab that opens the calibration in a window of its own (a second `uifigure`), with room for the steps table, a plot of angle against PWM going up and going down, and the result. A listener on CubeGUI's window (`ObjectBeingDestroyed`) closes it with CubeGUI, so it's never left behind. It plans a sweep from `SERVOn_MIN` to `SERVOn_MAX` and back, in `steps` PWM values. It moves the servo with `cube.moveServoPwm` (which applies the same limits and rate limit as `moveServo`, but in µs) and keeps each recorded angle in its panel's `UserData`. At the end, `engine/calibrationTable.m` averages each PWM's up and down angles into `[angle, pwm]` points, works out the hysteresis, refuses data that isn't monotonic, and returns the `units` and `mapping` text to paste into the settings file. **Back** goes one step back to measure it again, also from the end (the last step), and switches Record back on. **Copy settings** puts the text on the clipboard (`clipboard("copy", ...)`), and the window says where to paste it. The plot is redrawn when Record is clicked: a button's callback, not a MAVLink one, so it doesn't break the no-plotting-in-callbacks rule.

## The window's size

`windowPosition` (in `CubeGuiApp.m`) makes the window smaller if the screen needs it, keeping room for a taskbar and the title bar. On a laptop with its display scaled to 150 %, the screen is only about 1280 × 720 in MATLAB's pixels, and a 780-pixel-high window had its title bar off the top, where it couldn't be dragged back. The calibration window opens no bigger than CubeGUI's.

**Text that doesn't fit.** Checked on 4 November with screenshots (`exportapp`) at 1180 × 780 and at 1240 × 630, about what a 150 % laptop gets:

- The Setup tab's right-hand column has fixed heights and scrolls when the window is short, rather than squashing a box until its text is cut off. Its notes are kept short (the Firmware over USB box's full explanation is its hover text, `Tooltip`).
- Messages that change, and can be long (the status line, the log file's name, the download, flash and install messages), go through `showText`, which sets the label's `Tooltip` to the same text: hovering shows all of it. MATLAB doesn't do this for a label by itself. It only sets them when the text changes, since some update 10 times a second.
- Over USB the port's drop-down takes the space of the Cube port and Listen port boxes, which don't apply: a Mac's port names are long (`/dev/cu.usbmodem21301 (MAVLink)`).
- A servo plot's y-axis marks only `SERVOn_MIN`, `TRIM` and `MAX` (`showServoTicks` in `plotPanel.m`), so a short plot's numbers don't overlap.
- The calibration panel on the Run tab says only "So its slider can work in degrees.", with the full sentence on hover; its third line was cut off.
- The Setup table's Notes column is cut off at the table's edge; MATLAB's table shows a cell's whole text when you hover over it (Robin, 4 November).

## The safety switch button

After every reboot the Cube holds the servos still until the safety switch is turned off. The panel at the top of the Run tab has no title; its bold label says "Safety switch ON: servos held still" or "Safety switch OFF: servos live", so the state is always next to the words "Safety switch". Its button asks first (turning it off), then calls `source.setSafety(on)`.

`CubeSource` sends `MAV_CMD_DO_SET_SAFETY_SWITCH_STATE` (command 5300, ArduPlane 4.6 and later). MATLAB's message dictionary is older than that command, so CubeGUI builds a `COMMAND_LONG` for another command and changes its number. If the Cube replies "unsupported" (older firmware), CubeGUI switches to the older way that Mission Planner uses: `SET_MODE` with only the safety flag set. Either way it re-sends up to three times until `SYS_STATUS` shows the change.

CubeGUI never arms the Cube.

## The Setup tab: reading and writing parameters

`setupParameters` returns the hand-picked list: what CubeGUI needs (each servo's `SERVOn_FUNCTION` free), each servo's `SERVOn_MIN/TRIM/MAX` (its limits in CubeGUI, checked to be within 1000–2000) and `SERVOn_REVERSED`, safety (including `THR_FAILSAFE`, shown but not required: see `decisions.md`) and arming, logging and Lua, and the telemetry link. Each entry says what value is wanted (if any), how to check it, whether it's read-only, and a one-line note for students. `setup.extraParams` in the settings, or the **Add** box, adds more.

**Reading:** on connect, CubeGUI sends a `PARAM_REQUEST_READ` for each name. Answers arrive as `PARAM_VALUE` and land in `Telemetry.Params`. Missing ones are re-asked once a second for 10 s; after 8 s the table says "Not on this Cube" (true, for example, of the `STEST_` parameters until `servo_slew.lua` has run).

**Writing:**

1. The "New value" column holds what you typed, or, if a needed parameter is wrong, the value CubeGUI needs.
2. **Apply changes...** lists every change (name, current value, new value) and asks before writing anything.
3. On "Write to Cube", each one goes as a `PARAM_SET`. The Cube answers with a `PARAM_VALUE` showing the new value.
4. The redraw timer checks for that answer. No answer in 1.5 s means re-send, up to three times; then the status line says the Cube didn't accept it.
5. `SERIAL1_*` (the telemetry link) are read-only here. A wrong value would cut the laptop off from the Cube.
6. **Rebooting.** `SCR_ENABLE` and `BRD_SAFETY_DEFLT` only take effect after a restart (`CubeGuiApp.RebootParams`). Writing either brings a second question, "Reboot the Cube now?". If yes, `checkRebootAfter` (in the redraw) waits until the Cube has confirmed the new value, then calls `source.reboot()`: `MAV_CMD_PREFLIGHT_REBOOT_SHUTDOWN` (246) with param1 = 1. ArduPilot refuses it while armed, saves pending parameters, forces the safety switch on and restarts (`GCS_Common.cpp`, `AP_Vehicle.cpp`). The **Reboot Cube...** button does the same at any time, after a warning. CubeGUI stays connected, and `checkReboot` notices the Cube's clock starting again and reads its parameters afresh. The Simulated source's `reboot` restarts its clock and turns its safety switch on, to match.

The right-hand side shows the firmware version (from `AUTOPILOT_VERSION`) and the Lua values (from `NAMED_VALUE_FLOAT`).

## Logging

`CsvLogger` is the only code that knows the log's format. On **Connect** (or the Logs panel's **Start**), it creates `logs/CubeGUI_<date>_<time>.csv`, writes the header, and starts a timer that runs every 0.5 s. Each time, it:

1. takes the pitch samples newer than the last row written;
2. for each one, finds the last command sent at or before that sample's Cube time, and the latest output report at or before it. Commands are timed on the laptop's clock, so the logger converts them using the difference between the two clocks: the smallest gap seen between a sample's Cube time and its arrival, from the sample held up least. (Matching by arrival instead put commands seconds early when samples arrived late.)
3. writes one row per pitch sample: UTC time, laptop POSIX time, Cube time in ms, pitch, then `_cmd_us` and `_out_us` for each servo;
4. opens the file, appends, and closes it, so a crash loses at most half a second.

When the Cube reboots (`Telemetry.RebootCount` goes up), the logger starts counting Cube time again from zero, so the rows after the reboot are written too.

Message callbacks never write to the file.

### The Logs panel and the Cube's own log

The Logs panel (`buildLogsPanel`, updated by `updateLogs` in the redraw) is part of the engine. **Laptop** starts and stops `CsvLogger`; stopping saves the file, and starting makes a new one. **Cube** shows `LOG_DISARMED` and flips it between 0 and 1 through `confirmed`/`writeParams`, after a dialog showing the change. That's the only way to start and stop the Cube's log without arming: ArduPilot has no command for it and a Lua script can't (see `decisions.md`). Setting it to 0 pauses the log; the file stays open and carries on when it's set to 1 again. A download closes it, so the next start makes a new file (both seen on SITL).

**Download Cube log...** (a real Cube only, with its log stopped) uses `engine/LogDownload.m`. `list` asks for `LOG_REQUEST_LIST`; the `LOG_ENTRY` callback adds each log's number and size; once they're all in (or 3 s pass), the window offers the newest, with a time estimate. `download` asks for all of it with one `LOG_REQUEST_DATA`; the `LOG_DATA` callback copies each 90-byte piece into place and marks it arrived. `tick` (10 times a second, from `updateLogs`) asks for the next gap as soon as the range it asked for is complete, or after 1.5 s of silence (giving up after 10 silent tries), and when every piece has arrived writes the file and sends `LOG_REQUEST_END`, so the Cube goes back to logging. `LogDownload` never sends anything itself: it hands back requests, which `CubeSource.sendLogRequests` sends. So the callbacks hold the `LogDownload`, not the source, as with `Telemetry`. Disconnecting mid-download sends `LOG_REQUEST_END` too.

## Shutting down

Closing the window calls `CubeGuiApp.close`, which, in order:

1. stops and deletes the redraw timer;
2. disconnects: forgets the source first (so a redraw that sneaks in while the network shuts down finds no source, rather than a half-deleted one), then stops the logger (writing its last rows), stops and deletes the source's timer, drops the subscriptions, and closes the UDP port;
3. deletes the window.

It's done explicitly, step by step, rather than left to MATLAB tidying up objects, because a forgotten timer keeps running in MATLAB after the window has gone. The tests check that no timers are left (`timerfindall` is empty).

## The settings file

`config/cubegui.json` holds everything students are expected to change: the level, connection ports and address, logging on/off and folder, telemetry rate and plot length, the list of servos (name, output, and optional units, range and mapping), and the `plots` and `controls` panel lists. The servos' PWM limits aren't here: they're the Cube's own parameters. `config/README.md` explains each entry for students. Another file can be used with `CubeGUI(ConfigFile="config/kit7.json")`.

## The files, in reading order

| File | Role |
|---|---|
| `CubeGUI.m` | Launcher |
| `engine/loadConfig.m` | Reads and checks the settings |
| `engine/levels.m` | The capability levels |
| `engine/RingBuffer.m` | Fixed-size history |
| `engine/Telemetry.m` | The shared store |
| `engine/DataSource.m` | The interface both sources share; the PWM clamp |
| `engine/SimulatedSource.m` | Pretend Cube in MATLAB |
| `engine/CubeSource.m` | Real Cube over MAVLink/UDP |
| `engine/ServoMapping.m` | Slider units ↔ PWM |
| `engine/Cube.m` | The object panels are given: signals, servos, limits, rate limit |
| `engine/setupParameters.m` | The Setup tab's parameter list, by level |
| `engine/CsvLogger.m` | The CSV log |
| `engine/LogDownload.m` | Downloading the Cube's own log |
| `engine/FtpUpload.m` | Copying a file onto the Cube (for installing `cubegui.lua`) |
| `engine/FirmwareUpload.m` | Flashing firmware through the Cube's bootloader, over USB (level 1) |
| `engine/CubeGuiApp.m` | The window's frame, its timers, hosting the panels, and the engine's own panels (safety switch, Logs, gains, script install) |
| `panels/*.m` | The plots, sliders, readouts and buttons on the Run tab |
| `lua/cubegui.lua` | The Cube-side script for RC and closed-loop modes |
| `docs/recipes.md` | The students' guide to changing CubeGUI |

Outside those:

- `scripts/step2_connect.m`, `step3_servo.m`, `step4_live_plot.m`: the small learning scripts, each a self-contained step (connect and print; send one clamped servo command; a live plot from a timer). They show the patterns `CubeSource` and `CubeGuiApp` use, without the classes.
- `tests/`: automated checks with `matlab.unittest`, run with `runtests("tests")`. The window tests use the Simulated source; nothing in `tests/` touches the network.
- `tools/fake_cube.py`: a pretend Cube in Python (pymavlink) that answers like a real one over UDP, and prints everything CubeGUI sends. `--uptime 2400` makes it pretend it booted 40 minutes ago, for testing long sessions. `tools/gcs_check.py` checks a Cube, real or fake, answers the way CubeGUI expects.

## MATLAB features a Python programmer will trip over

| MATLAB | Python equivalent, roughly |
|---|---|
| `classdef X < handle` | an ordinary class: variables share one object |
| a class without `< handle` (`ServoMapping`) | a frozen dataclass: copies behave like numbers |
| `properties (SetAccess = private)` | a read-only `@property` |
| `methods (Access = protected)` | `_method`, but enforced |
| `methods (Abstract)` in `DataSource` | `abc.ABC` with `@abstractmethod` |
| `@(src, event) obj.redraw()` | `lambda src, event: obj.redraw()` |
| `feval("servoPanel", ...)` | calling a function by its name, like `globals()["servoPanel"](...)` |
| `methods (Hidden)` | public, but left out of `dir()` and tab completion |
| `containers.Map` | an older `dict`; used where the values are objects (the Lua histories) |
| `arguments` block | type hints plus validation at the top of a function |
| `dictionary` | `dict` |
| `string` vs `char` | `"text"` is a string object; `'text'` is a character array, more like a list of characters |
| `obj.method()` and `method(obj)` | both mean the same call |
| `field(:) = value` | assign into an existing array, keeping its type (used on MAVLink payload fields) |
| `gobjects(1, n)` | a list of `n` empty slots for graphics objects |
| `timer` | `threading.Timer` repeating, but run on MATLAB's single thread between other work |
