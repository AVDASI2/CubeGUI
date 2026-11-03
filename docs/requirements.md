# CubeGUI requirements

CubeGUI is a MATLAB ground station for the AVDASI 2 wind-tunnel test. Students use it to watch a model fuselage, controlled by a Cube Orange+ running ArduPlane, move servos, and log data, all from one window.

Priorities, in order: **reliable**, **easy to use**, then everything else.

This document is the spec. Where something hasn't been confirmed on real hardware it says so. Questions still waiting for an answer are listed at the end.

## 1. Starting point

CubeGUI assumes the Cube is in the state the AVDASI 2 step-by-step guide leaves it in (pages 03 to 06b at <https://avdasi2.github.io>):

- ArduPlane, freshly flashed (Sub, then Plane), so every parameter starts at its default.
- Telemetry over the Beyond Robotix Kahuna on TELEM1, in point-to-point mode. The laptop joins the Wi-Fi network `AVDASI2 - Kit X` and talks to the Cube over UDP.
- `THR_FAILSAFE = 0`.
- `SERVOn_FUNCTION = 0` on every output CubeGUI drives.
- The servo rail powered from the UBEC on AUX OUT 1.
- The safety switch must be toggled off after every reboot before any PWM reaches the servos.

Output numbering: MAIN OUT n is `SERVOn`, AUX OUT 1 is `SERVO9`.

## 2. Scope

- **One window, for the fuselage test only.** Flap, aileron and full-vehicle versions are out of scope, but the code should make them easy to add later (surfaces and plots come from the config file, not hard-coded).
- The Cube's own dataflash log is downloaded with Mission Planner. CubeGUI doesn't replace that; it links to how.

## 3. Functional requirements

### 3.1 Data sources

CubeGUI talks to one of two interchangeable data sources through the same interface:

| Source | What it is | Where it runs |
|---|---|---|
| **Cube** | Real MAVLink over UDP (serial as an option) | Desktop MATLAB, on a laptop joined to the Kahuna's Wi-Fi |
| **Simulated** | Generated inside MATLAB: a swinging pitch, and servo commands echoed back as outputs | Anywhere, including MATLAB Online. Doubles as a demo mode before the kit is wired up |

For desk testing without hardware, `tools/fake_cube.py` (Python, pymavlink) pretends to be a Cube behind a Kahuna, using the same ports. It sends heartbeats, `ATTITUDE` with a swinging pitch, `SERVO_OUTPUT_RAW` and `AUTOPILOT_VERSION`, answers parameter requests, and prints every command it receives. `tools/gcs_check.py` is a Python check that a Cube, real or fake, answers the way CubeGUI expects.

### 3.2 Live plots

- Pitch, elevator, rudder and GEAR (believed to be landing gear; to be confirmed).
- Show about the last 30 s, scrolling.
- Pitch comes from `ATTITUDE`. Servo positions come from `SERVO_OUTPUT_RAW`, so the plots show what the Cube is actually outputting, not just what was asked for.

### 3.3 Servo controls

For each of elevator, rudder and landing gear:

- a slider and a numeric box, kept in step with each other;
- slider units from the config file: PWM in µs by default (from `SERVOn_MIN` to `SERVOn_MAX`; changed from percent on 2026-11-03), degrees of deflection once calibration data exists;
- a mapping from slider value to PWM, chosen in the config file:
  - a lookup table with linear interpolation, or
  - an equation: linear (`pwm = m*x + c`), exponential, or a custom expression.

PWM is a pulse width in microseconds, roughly 1000 to 2000. It is never an 8-bit 0 to 255 value.

A **Zero all** button sends every servo its trim PWM.

### 3.4 Setup panel

- Reads the Cube parameters CubeGUI depends on (at least `SERVOn_FUNCTION`, `_MIN`, `_TRIM` and `_MAX` for each configured output) and shows whether each has the expected value. `THR_FAILSAFE` is shown but any value is accepted: it doesn't affect servos driven by CubeGUI on a disarmed Cube (decided 2026-10-31).
- Writes parameters only when the user clicks **Apply**, after a confirmation dialog that lists exactly what will change (name, current value, new value).
- Shows the hardware and software versions from `AUTOPILOT_VERSION`.
- Reminds the user that the safety switch must be toggled after every reboot.

### 3.5 Arming

- CubeGUI **never arms by default**. Moving a servo is believed not to need arming; this is unverified until the bench run.
- If an Arm button is added, it needs a confirmation dialog, and force arm needs its own warning: force arming skips the safety checks, which is acceptable with only servos attached and never with a motor or propeller.

### 3.6 Logging

- **Telemetry log** on the laptop:
  - CSV, one row per sample, at 20 Hz (5 Hz acceptable);
  - on by default while connected;
  - a new file per run, named by date and time, e.g. `logs/CubeGUI_2026-10-20_14-03-27.csv`;
  - flushed to disk at least once a second, so a crash loses at most a second;
  - every row has the laptop's UTC time and the Cube's `time_boot_ms`. `SYSTEM_TIME` is logged so Cube boot time can be converted to UTC afterwards;
  - commanded PWM is logged alongside measured PWM.
  - The laptop time is when MATLAB *handled* the sample. While MATLAB is busy that can lag by a few hundred milliseconds, so the Cube's `time_boot_ms` is the accurate clock between samples, and the laptop time is for lining up with other systems to within about a second. A tighter line-up (estimating the offset between the two clocks) can be done afterwards if the tunnel work needs it.
- Only the logger module knows the file format, so it can change later without touching anything else.
- **Cube dataflash log:** downloaded afterwards with Mission Planner. CubeGUI links to the guide's Data Logging page.
- **Later, maybe:** the tunnel's own system (angle of attack, airspeed, loads) stays in its own log. CubeGUI's UTC timestamps should be enough to line the two up afterwards.

### 3.7 Configuration

A JSON file in `config/` holds everything students might need to change, without touching code:

- the output number for each surface;
- slider units, and the mapping or calibration table for each surface;
- connection settings (UDP port, remote address if needed);
- message rates, plot window length, log folder.

CubeGUI checks the file when it loads and gives a plain-English error naming the bad entry.

## 4. Architecture

```text
 Cube ──MAVLink/UDP──► comms (one owner of the connection) ──► latest-value buffer + ring buffers ──► GUI timer (10–20 Hz) ──► plots, readouts
   ▲                         │                                          │
   └── commands / params ────┘                                          └──► logger (CSV, flushed often)
```

- **Comms** owns the connection. Message callbacks only store data; they never touch the window.
- **Buffers:** a latest-value store, plus fixed-length ring buffers holding about 30 s of each plotted signal.
- **The GUI** redraws from a MATLAB `timer` every 50 to 100 ms. Nothing is plotted inside a message callback.
- **The window is built in code** (`uifigure`, `uigridlayout`, `uiaxes`, `uislider`, `uilamp` and so on, in `.m` files), not App Designer, so every change shows up as readable text in git.
- **Engine and panels** (built 2026-10-31, roadmap 7.1). The connection, buffers, logging, safety rules and the window's frame are in `engine/`. Each plot, slider, readout or button on the Run tab is a short function in `panels/`, listed in the settings file. Panels talk to the engine only through one object, `cube`, which applies the safety rules (Cube limits, clamp, at most 10 servo commands a second). A panel that errors is replaced by a red message naming its file and line; the rest of the window carries on. Students change CubeGUI through the settings file and by copying panels; `docs/recipes.md` shows how.
- **Capability levels** (roadmap 7.2): one `level` setting, 1 to 6, decides which engine features, panels and Setup-tab parameters appear. Levels hide features; they don't lock them.
- **MAVLink** goes through MATLAB's UAV Toolbox (`mavlinkdialect`, `mavlinkio`, `mavlinkclient`, `mavlinksub`, `createcmd`, `createmsg`, `sendudpmsg`). Function names and signatures are checked against MathWorks' documentation before use.
- **Works on R2026a.** UAV Toolbox R2026b added "microservices" that send heartbeats, read and write parameters, and wait for command acknowledgements, plus serial connections. Until we know the lab laptops have R2026b, CubeGUI does these by hand with the R2026a functions: a 1 Hz `timer` sends CubeGUI's own heartbeat, and parameters use `PARAM_REQUEST_LIST`, `PARAM_REQUEST_READ`, `PARAM_SET` and `PARAM_VALUE` directly. (There's no `mavlinkparameter` function, despite earlier notes.)

### 4.1 The connection

From the Kahuna's firmware source (not yet checked on a real kit):

- The Kahuna is at `192.168.4.1`. It sends the Cube's messages to UDP port **14550** on the laptop, from its own port **14555**, and listens on 14555 for anything coming back.
- Until it hears from a ground station it broadcasts to the whole network. Once it does, it sends only to that laptop. If the laptop goes quiet for 10 s it goes back to broadcasting, so CubeGUI must keep sending its own heartbeat.
- In point-to-point mode it stops handing out network addresses after the first ground station connects, so expect one laptop per kit.
- The Kahuna also sends its own messages (`RADIO_STATUS`), as component 240. CubeGUI must only treat heartbeats from the autopilot (component 1) as "connected".

CubeGUI listens on 14550 and sends to `192.168.4.1:14555`. Both are in the config file.

### 4.2 MAVLink messages

| Message | Used for |
|---|---|
| `HEARTBEAT` | Connection health |
| `ATTITUDE` | Pitch |
| `SERVO_OUTPUT_RAW` | What each output is actually doing |
| `AUTOPILOT_VERSION` | Hardware and software versions, requested with `MAV_CMD_REQUEST_MESSAGE` |
| `SYSTEM_TIME` | Converting the Cube's boot-time stamps to UTC |
| `NAMED_VALUE_FLOAT` | Values sent by Lua scripts with `gcs:send_named_float()` |
| `PARAM_VALUE` | Parameter reads and write confirmations |

Rates are requested explicitly with `MAV_CMD_SET_MESSAGE_INTERVAL`, aiming for 20 Hz on `ATTITUDE` and `SERVO_OUTPUT_RAW`.

### 4.3 Servo commands

- Sent as `MAV_CMD_DO_SET_SERVO` (servo number, PWM).
- Every command is **clamped** to the servo's minimum and maximum PWM before it's sent. There's no way round the clamp from the window.
- **The limits are the Cube's own `SERVOn_MIN`, `SERVOn_TRIM` and `SERVOn_MAX`** (decided 2026-10-23), so CubeGUI, RC and Lua scripts share one set. CubeGUI reads them on connect and follows any change. Its sliders stay off until they've arrived. Limits outside 1000–2000 µs, or not in the order MIN < TRIM < MAX, are refused: that servo isn't driven at all until they're fixed.
- **The Cube doesn't clamp `DO_SET_SERVO` itself.** On an output with `SERVOn_FUNCTION = 0`, ArduPilot sends the commanded PWM straight out, ignoring `SERVOn_MIN/MAX` (checked in `AP_ServoRelayEvents.cpp` and `SRV_Channel.cpp`, and seen on a real Cube on 2026-10-23). CubeGUI's clamp is the only one.
- **Rate-limited:** sent on slider release, and at most about 10 Hz while dragging.
- Only works on outputs whose `SERVOn_FUNCTION` is 0, 1 or 51 to 66. Otherwise the Cube refuses it ("Channel x is already in use"). The Setup panel flags any configured output that isn't free, and CubeGUI reports a refused command in plain English.
- ArduPilot's source has no arming check on this command, which supports the belief that arming isn't needed. The safety switch is what holds the servos back. Both to be confirmed on the bench.

## 5. Reliability requirements

- **Status lamp:** green while heartbeats arrive, red after about 2 s without one.
- **Automatic reconnection** when heartbeats come back, without the user doing anything. Checked at the desk with `fake_cube.py` (2026-10-21): after a Wi-Fi drop, the Cube switching off, and a reboot, the lamp goes red within 2 s, then green again, and the 20 Hz rates come back on their own.
- **Cube reboots** are spotted from its clock going backwards. CubeGUI then says so in the status line (the safety switch is on again), reads the parameters and version again, and the log carries on. A reboot must never be mistaken for `SERVO_OUTPUT_RAW`'s clock wrapping round at 71.6 minutes.
- **Late messages.** Over Wi-Fi (and through the VM) samples can arrive late and out of order: up to 7 s late in the real-Cube test on 2026-10-23. A late sample is skipped, not mistaken for a reboot. A jump backwards only counts as a reboot if the Cube's clock is under a minute, or samples keep arriving behind for 3 s.
- **Connecting to a Cube that has been on for over 71.6 minutes** (it had, on 2026-10-23): `SERVO_OUTPUT_RAW`'s clock has already wrapped, so it's lined up using `ATTITUDE`'s millisecond clock, which doesn't wrap for 49 days.
- **Plain-English errors.** In particular, if the UDP port is already taken, say so and suggest the likely cause: "Port 14550 is already in use. Is Mission Planner open? Close it, or use its MAVLink forwarding to send the data to another port." Mission Planner and CubeGUI can't both listen on the same port on one laptop. MATLAB's error from `connect` passes on the operating system's error and its number: on macOS, "Address already in use [system:48 ...]". CubeGUI checks the text and the number (48 macOS, 98 Linux, 10048 Windows). The Windows text and number come from Microsoft's documentation and are still to be seen from MATLAB.
- **Parameters** are read on connect, and written only after confirmation (3.4).
- **Clean shutdown:** closing the window disconnects, stops every timer and closes the log file. No orphaned timers left running in MATLAB.
- **Don't lose messages while MATLAB is busy.** A `mavlinksub` subscription keeps only its newest message unless given a bigger `BufferSize`, so messages that arrive while MATLAB is busy (opening a window, say) are dropped before any callback sees them. In testing that left a 2 s gap in the log. CubeGUI's subscriptions hold 200 messages, about 10 s at 20 Hz.
- **Careful with callbacks.** A callback that can see another function's variables (a nested function) keeps them all alive, and in milestone 2 that stopped the cleanup from running and left a timer going. Shutdown is done explicitly, never left to MATLAB deleting objects, and tests check `timerfindall` is empty afterwards.

## 6. Testing

Robin's Mac has MATLAB R2026b with UAV Toolbox, so the automated tests and desk tests run there. There are three test setups:

1. **MATLAB Online + Simulated source:** everything except the connection.
2. **Desktop MATLAB + `fake_cube.py`:** the real MAVLink path, at a desk.
3. **Desktop MATLAB on a second laptop + a real Cube:** the full test, including a bench run to settle the arming question.

MATLAB Online can't reach the Kahuna, USB devices, or anything on the local network.

## 7. Milestones

Each one works, and is tested, before the next starts.

0. Spec, README, `.gitignore`.
1. `tools/fake_cube.py`.
2. Connect: a script that connects over UDP and prints heartbeats and pitch.
3. Move a servo: `DO_SET_SERVO` to servo 5, clamped.
4. Live plot of pitch from a timer, still in a script.
5. The window: connect/disconnect, status lamp, pitch plot, one servo slider, Simulated source. Tested in MATLAB Online.
6. CSV logging.
7. The rest of the controls: three servos, mapping and calibration config, Zero all, Setup panel, version display.
8. Robustness: reconnection, port-in-use detection, clean shutdown, bench test with a real Cube. Desk-testable parts done 2026-10-21; still to do: the port-in-use message on Windows, measuring drop-outs from a real log, and the bench test.
9. Docs: a "how to use" section in the README, and a draft page for the AVDASI 2 site.

## 8. Open questions

| # | Question | Needed by |
|---|---|---|
| 1 | Is "GEAR" landing gear? Assumed so; the servo is called "Gear" in the settings. | Before the bench test |
| 2 | Which MAIN outputs do elevator, rudder and landing gear use? The settings use 5, 6 and 7 as placeholders; only 5 comes from the guide. | Before the bench test |
| 3 | Which MATLAB release is on the lab laptops, exactly (R2026a or R2026b?), and is UAV Toolbox installed? (Robin's Mac has R2026b with UAV Toolbox 26.2.) R2026b would let CubeGUI use MathWorks' heartbeat and parameter helpers and serial. | Milestone 2 |
| 4 | Kahuna address and ports. The firmware source says `192.168.4.1`, sending to the laptop's port 14550 from port 14555 (section 4.1). To confirm on a real kit. | Milestone 8 |
| 5 | Is arming ever needed for servo output? To be settled by the bench run. | Milestone 8 |
| 6 | Should CubeGUI toggle the safety switch? Recent ArduPilot handles `MAV_CMD_DO_SET_SAFETY_SWITCH_STATE` (command 5300), which would save students a trip to Mission Planner after every reboot. Older firmware may not, so it depends on the version on the kits. (Setting `BRD_SAFETY_DEFLT = 0` would remove the switch altogether, which is a safety decision for the supervisor.) | Milestone 7 |
| 7 | The guide's Data Logging page says the Cube must be armed to log. ArduPilot's documentation says `LOG_DISARMED = 1` logs all the time, armed or not. Should the Setup panel check for it, and should the guide mention it? | Milestone 7 |
| 8 | Is tunnel-system integration feasible, and what does it log? | Later |
| 11 | Values from Lua scripts (`NAMED_VALUE_FLOAT`) are shown in the Setup tab but not logged, because their names aren't known in advance. Should they be logged, and in which file layout? | When a Lua script needs it |
| 9 | Should RC (the FrSky receiver) be part of the minimum working example? | Later |
| 10 | Licence? To ask the supervisor. The docs site is considering CC BY 4.0. Any ArduPilot code copied in is GPLv3. | Before the repository goes public |
