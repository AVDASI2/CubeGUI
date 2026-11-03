# The Cube's own flight log

Besides CubeGUI's CSV log on the laptop, the Cube keeps its own, far more detailed log on its SD card: every sensor, its attitude at 25 times a second, its servo outputs, and anything `cubegui.lua` writes. This page explains how to switch it on, mark your runs in it, get it off the Cube, and line it up with CubeGUI's log.

| | CubeGUI's CSV | The Cube's log (`.bin`) |
|---|---|---|
| Where | the laptop's `logs` folder | the Cube's SD card, `APM/LOGS` |
| What | pitch, pitch rate, servo commands and outputs, Lua values you list, markers | almost everything the Cube knows |
| Rate | 20 rows a second | attitude 25 a second, sensors faster |
| Gaps | if the Wi-Fi drops out | none: it's written on the Cube |
| Clock | `cube_time_ms` (the Cube's clock) and UTC | `TimeUS` (the same Cube clock, in microseconds) |

## Starting and stopping it

The Cube only logs while armed, unless `LOG_DISARMED` is 1. CubeGUI never arms the Cube, so it starts and stops the Cube's log by changing `LOG_DISARMED`. From level 1, the **Logs** panel on the Run tab does it:

1. Connect. The **Cube** line says whether the Cube is recording.
2. Click **Start** next to **Cube**. CubeGUI asks first, showing the change (`LOG_DISARMED: 0 → 1`), then writes it.
3. Click **Stop** when you've finished. That writes `LOG_DISARMED` back to 0.

Things to know:

- **The Cube saves the change**, so if you don't stop it, it carries on logging after a reboot.
- **Stopping pauses the log rather than closing the file.** Start again and the Cube carries on in the same `.BIN` file. A new file (`00000001.BIN`, `00000002.BIN`, ...) starts when the Cube powers up, or when you start the log again after downloading one (a download closes the file). ArduPilot has no command for starting a new file without arming, and a Lua script can't start or stop the log either. Use run markers (below) to find each run in the file. (All checked on ArduPilot's simulator, 3 November: while stopped, the file grew by a few hundred bytes in 5 s, against about 57 kB a second while recording.)
- **Logs are big:** about 3 MB a minute (measured in ArduPilot's simulator: 205 MB in an hour). So only record while you're testing, and download what you need before the next session.

## Marking your runs

Add a `markerPanel` to `controls` (it's there from level 1 in the shipped settings), type a note such as `run 3: 10 m/s, AoA 4`, and click **Mark**. The note goes:

- into CubeGUI's log, in the `marker` column, in the row where you clicked;
- into the Cube's log, as a `MSG` entry reading `GCS:CubeGUI: run 3: 10 m/s, AoA 4` (the Cube adds `GCS:`).

The markers are the easiest way to find each run in either log, and to check the two logs line up.

## Getting it off the Cube

Leave the SD card in the Cube. Fastest first:

1. **CubeGUI over USB** (the usual way): plug the Cube into the laptop with a USB cable, choose **Cube (USB)** and connect, stop the Cube's log, then click **Download Cube log...** in the Logs panel. CubeGUI asks the Cube for its list of logs, says how big the newest one is, and saves it in the `logs` folder as `Cube_log<number>_<date and time>.BIN`. Over USB the Cube sends logs far faster: about 280 kB a second on a Cube Orange+ (a 0.4 MB log took 1.5 s; timed on 4 November). USB needs MATLAB R2026b or later. Mission Planner can do the same: **DATA** tab > **DataFlash Logs** > **Download DataFlash Log Via Mavlink**, with CubeGUI closed.
2. **CubeGUI over the Wi-Fi** (`Cube (Wi-Fi)`): the same button, but slow. The Kahuna's link to the Cube runs at 57600 baud, and on a kit it managed about 4 kB a second (0.5 MB, ten seconds of logging, took 2 minutes; timed on 3 November). So **each minute of logging takes about 12 minutes to download** this way. Fine for a short run, or to leave going while you do something else; use USB for anything longer.

The Cube doesn't log while it sends a log, and it must be disarmed, which it always is with CubeGUI.

## Reading it in MATLAB

UAV Toolbox reads `.bin` files with `ardupilotreader`:

```matlab
log = ardupilotreader("00000003.BIN");
msgs = readMessages(log, MessageName=["ATT", "MSG", "CGUI"]);
att = msgs.MsgData{msgs.MsgName == "ATT"};      % a timetable: TimeUS, Pitch, DesPitch, Roll, ...
notes = msgs.MsgData{msgs.MsgName == "MSG"};    % the Cube's messages
markers = notes(contains(notes.Message, "CubeGUI:"), :)   % just your run markers
```

`TimeUS` comes out as a duration since the Cube powered up: `milliseconds(att.TimeUS)` gives the same numbers as CubeGUI's `cube_time_ms`. Opening a 200 MB log takes 15 s or so. (Checked on 2026-11-01 with a log from ArduPilot's simulator.)

MATLAB's **Flight Log Analyzer** app (`flightLogAnalyzer`) can plot it too. See the AVDASI 2 guide's Data Logging page.

## Lining the two logs up

Both logs use the Cube's own clock, counting from when it powered up:

- CubeGUI's `cube_time_ms` is the Cube's clock in milliseconds;
- the `.bin` file's `TimeUS` is the same clock in microseconds.

So a CubeGUI row with `cube_time_ms` = 754000 happened at `TimeUS` = 754000000 in the Cube's log, exactly, as long as both come from the same power-up. A reboot starts both clocks again from zero. The markers are the check: each one appears in both logs at the same moment, to within a fraction of a second.

To line either log up with the tunnel's own data system, use CubeGUI's `utc_time` column, which is the laptop's clock. That's good to about a second, depending on how well the laptop's clock is set.

## Values from cubegui.lua

From level 2, `cubegui.lua` writes a `CGUI` entry 10 times a second, with its mode, SAS, pitch target, pitch, pitch rate, the P, I and D terms, and the elevator PWM. That's everything needed to study the closed loop afterwards, at a steadier rate than the Wi-Fi gives CubeGUI.
