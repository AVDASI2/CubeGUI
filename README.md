# CubeGUI

A MATLAB ground station for the AVDASI 2 wind-tunnel test. One window shows live plots of the fuselage's pitch and servo positions, lets you move the servos, and logs everything to a CSV file on your laptop.

It works with a Cube Orange+ running ArduPlane, set up as in the [AVDASI 2 step-by-step guide](https://avdasi2.github.io). There's also a simulated mode that needs no hardware, so you can try it out first.

> [!WARNING]
> **Not for flight.** CubeGUI has been lightly tested: on ArduPilot's simulator and on the bench with a real Cube. It's suitable for careful wind-tunnel and bench testing of a model that's held in place. It is **not** suitable for controlling anything that flies. Nothing in it has been through the testing a flight system needs, it talks to the Cube over Wi-Fi that can drop out, and some of it was written with an AI assistant (see [How CubeGUI was made](#how-cubegui-was-made), near the end of this page).

**Status:** working, and tried on the bench with a real Cube. New features arrive in levels as the unit goes on (see below).

## What you need

- MATLAB R2026a or later, with **UAV Toolbox** (install it from the Add-On Explorer)
- For the real Cube: desktop MATLAB, on a laptop joined to your kit's Wi-Fi (`AVDASI2 - Kit X`), or with a USB cable to the Cube. The USB cable needs MATLAB R2026b or later
- For simulated mode: any MATLAB, including MATLAB Online

Close Mission Planner before you connect. Only one program at a time can listen for the Cube on a laptop, over the Wi-Fi or USB.

## Getting it

The best way is to clone it with git, so you can update it later (MATLAB's **Source Control** > **Pull**) without losing your own changes. MATLAB can do this itself, on Windows, Mac or Linux. In **MATLAB's Command Window** (the `>>` prompt in MATLAB, not Windows' Command Prompt), go to the folder you want CubeGUI in with `cd`, then type:

```matlab
gitclone("https://github.com/AVDASI2/CubeGUI.git")
```

Or, if you have git installed, the same from a terminal:

```bash
git clone https://github.com/AVDASI2/CubeGUI.git
```

Or download it as a zip from GitHub (**Code** > **Download ZIP**) and unzip it. To update a zip copy, download it again and copy your own files across.

## How to run it

1. Open MATLAB and set the Current Folder to the `CubeGUI` folder.
2. Type `CubeGUI` in the Command Window and press Return.
3. Choose a **Source**: `Simulated` to try it out with no hardware, `Cube (Wi-Fi)` for your kit through its Wi-Fi, or `Cube (USB)` for a USB cable to the Cube. For USB, CubeGUI looks at the USB ports and picks the one the Cube talks MAVLink on (marked **MAVLink**).
4. Click **Connect**. The lamp turns green when CubeGUI can hear the Cube.
5. Turn the safety switch off: the top of the right-hand side says **Safety switch ON: servos held still** until you click **Turn off**. The Cube turns it back on after every reboot, and the servos won't move while it's on.
6. Move a slider to move its servo. Each slider is the PWM sent to the servo, in microseconds, from the Cube's `SERVOn_MIN` to `SERVOn_MAX`; once you've calibrated a surface it can work in degrees instead. **Zero all** sends every servo back to its trim position. Close the window when you've finished.

## Levels

CubeGUI unlocks features in stages, as the unit goes on. The window's title shows the level, which is set by `"level"` in the settings file:

| Level | Name | What it adds | Status |
|---|---|---|---|
| 0 | Simulate | The Simulated source, its plots, and sliders that drive the simulation | Released |
| 1 | Connect and log | The real Cube, over the Wi-Fi or a USB cable; the safety switch, the servos and the Setup tab, with flashing ArduPlane and resetting to a fresh Cube; logging to CSV; starting, stopping and downloading the Cube's own log; run markers; values from Lua scripts; calibration | Released |
| 2 | RC | Control from your transmitter, a display of who's in charge, and installing `cubegui.lua` from the Setup tab | **Preview** |
| 3 | Closed loop | A pitch controller on the Cube, with its target and gains in CubeGUI | **Preview** |

`CubeGUI` opens at level 1.

**Levels 2 and 3 are previews.** They're in the code so you can see where CubeGUI is going, and you're welcome to look. But they've only been tested on ArduPilot's simulator, not on the kits, and **they aren't supported until they're released**: we won't help with them before then. They're planned for later in the unit (dates to be confirmed): RC before Gate 2a, and the closed loop in TB2. The window's title says "preview" at those levels.

Levels 2 and 3 need a Lua script, `cubegui.lua`, on the Cube: [lua/README.md](lua/README.md) explains how to install and set it up.

`CubeGUI(Level=1)` opens at another level without changing the settings file.

**Tunnel profiles.** For the wind-tunnel tests there are ready-made settings files, one per test, at level 3 (so also a preview for now): `config/fuselage.json`, `config/portwing.json` and `config/starboardwing.json`. Open one with, for example, `CubeGUI(ConfigFile="config/portwing.json")`. The wing ones are placeholders until the wing teams know their outputs and sensors.

## Logging

The **Logs** panel on the Run tab (from level 1) starts and stops two logs.

**Laptop: CubeGUI's CSV log.** It starts when you connect (unless `logging.enabled` is false in the settings) and goes in the `logs` folder, in a new file named by date and time. **Stop** saves it; **Start** begins a new file. Each row is one pitch reading, with:

- `utc_time` and `laptop_posix_s`: the laptop's clock when it arrived, for lining up with other data, such as the tunnel's;
- `cube_time_ms`: the Cube's own clock, in milliseconds since it booted, which is the accurate one between rows;
- `pitch_deg` and `pitch_rate_dps` (degrees per second);
- for each servo, `..._cmd_us`, the PWM CubeGUI sent, and `..._out_us`, the PWM the Cube reported.

Open it in MATLAB with `readtable`, or in Excel. A **Run marker** panel adds your notes, such as "run 3: 10 m/s", to a `marker` column, and to the Cube's own log. The first row's marker always says "log started". Values from Lua scripts can be logged too: see `logging` in [config/README.md](config/README.md).

**Cube: the Cube's own log.** Much more detailed, and kept on the Cube's SD card. **Start** and **Stop** switch it on and off (they change `LOG_DISARMED`, and ask first). Once it's stopped, **Download Cube log...** fetches the newest log. Connect with a USB cable (`Cube (USB)`) for this if you can: a few seconds for a typical log. Over the Wi-Fi it works too, but slowly: each minute of logging takes about 12 minutes. [docs/flight-log.md](docs/flight-log.md) explains it all, and how to line the two logs up.

## The Setup tab

The **Setup** tab checks the Cube parameters CubeGUI depends on at your level, and can fix them for you: it asks first, and shows exactly what will change. It also shows the Cube's firmware version and any values your Lua scripts send. From level 2 it can copy `cubegui.lua` onto the Cube.

Its **Firmware over USB** box needs a USB cable. **Flash ArduPlane...** installs ArduPlane, as Mission Planner's Install Firmware does, so Mac users don't need Mission Planner for it. Flashing keeps the Cube's settings. **Reset to a fresh Cube...** puts every setting back to its default, as flashing Sub then Plane does: you'll need to set the Cube up again from the step-by-step guide, including the calibrations it does in a ground station (Mission Planner or QGroundControl), which CubeGUI can't do. Both ask first. Over USB, CubeGUI reconnects by itself after the Cube reboots.

## Changing CubeGUI

Settings such as which output each servo is on, which plots and controls appear, and calibration tables (so a slider can work in degrees) are in `config/cubegui.json`. [config/README.md](config/README.md) explains them. Each servo's PWM limits are the Cube's own `SERVOn_MIN`, `SERVOn_TRIM` and `SERVOn_MAX`, which you can change in the Setup tab.

To add a plot, a servo, a button or a readout, see [docs/recipes.md](docs/recipes.md). Most need only a line in the settings file.

**Using an AI assistant to change it** is fine: CubeGUI is a tool for your tests, not something you need to learn inside out. [AGENTS.md](AGENTS.md) tells the assistant how to help well: to explain what it changes, to point out what matters for your test, and to keep reminding you that this isn't for flight. Read what it gives you, and check it in Simulated mode before you connect to the Cube.

## Reporting a problem

Something not working, or a mistake in these pages? Open an issue on [GitHub](https://github.com/AVDASI2/CubeGUI/issues): say what you did, what happened, and paste the message from CubeGUI's status line or MATLAB's Command Window. Levels 2 and 3 are previews, so they aren't supported yet.

## Testing without a Cube

`tools/fake_cube.py` pretends to be a Cube on the network, so you can test the real connection at a desk. It needs Python 3 and pymavlink:

On a Mac or Linux, in a terminal in the `CubeGUI` folder:

```bash
python3 -m venv .venv
.venv/bin/pip install pymavlink
.venv/bin/python tools/fake_cube.py
```

On Windows, in PowerShell or Command Prompt in the `CubeGUI` folder:

```bat
py -m venv .venv
.venv\Scripts\pip install pymavlink
.venv\Scripts\python tools\fake_cube.py
```

It sends to UDP port 14550 on the same computer, listens on port 14555 as the Kahuna does, and prints every command it receives. `tools/gcs_check.py` is a quick Python check that a Cube, real or fake, answers the way CubeGUI expects. For testing with ArduPilot itself, see [tools/sitl/README.md](tools/sitl/README.md).

## Folders

| Folder | What's in it |
|---|---|
| `config/` | Settings you can change: the level, the servos, the plots and controls, calibration, and the tunnel profiles. See its README. |
| `panels/` | The plots, sliders and buttons on the Run tab. Copy one to make your own. |
| `engine/` | The connection, logging and safety rules. You don't need to change anything here. |
| `lua/` | `cubegui.lua`, the script on the Cube for RC and closed-loop control (levels 2 and 3) |
| `docs/` | How to change CubeGUI (`recipes.md`), the Cube's own log (`flight-log.md`), and, for maintainers, how it works inside (`how-it-works.md`) |
| `scripts/` | Small step-by-step scripts used while building CubeGUI: connect, move a servo, live plot |
| `tests/` | Automated checks. In MATLAB, run `runtests("tests")` |
| `tools/` | `fake_cube.py`, a Python stand-in for the Cube, for testing without hardware, and `sitl/`, for testing with ArduPilot's own simulator |
| `logs/` | Your logs: CubeGUI's CSV files and any Cube logs you download (not stored in git) |

## How CubeGUI was made

CubeGUI was written by Robin Carter for AVDASI 2 at the University of Bristol, with a lot of help from Anthropic's Claude (Claude Code), an AI assistant. Robin decided what it should do and the safety rules it follows, reviewed the changes, and tested it against a real Cube; Claude wrote much of the code and documentation, and tested it on ArduPilot's simulator. Where the documentation says something was checked, it was checked against ArduPilot's source code, MathWorks' documentation, ArduPilot's simulator or a real Cube; anything not checked is marked **GUESS**.

That's one more reason it's not for flight: AI-written code can be wrong in ways that look right. Treat it as you would any unfamiliar code, and test before you trust it.

## Licence

MIT: see [LICENSE](LICENSE). You can use, copy and change CubeGUI freely, as long as the licence notice stays with it. It comes with no warranty.
