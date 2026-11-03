# cubegui.lua: RC and closed-loop control on the Cube

> [!WARNING]
> **Not for flight.** This script has been tested on ArduPilot's simulator and is meant for a model held on a wind-tunnel or bench rig. It is not a flight controller and must not be used on anything that flies.

> [!NOTE]
> **A preview.** Levels 2 and 3, which use this script, aren't released yet: they've been tested on ArduPilot's simulator but not on the kits, and aren't supported until they're released.

`cubegui.lua` runs on the Cube and decides who drives the servos:

| Mode | Who drives |
|---|---|
| **CubeGUI** | CubeGUI's sliders, as at levels 0 and 1. The script does nothing. |
| **RC** | The transmitter's sticks |
| **Closed loop** | A PID controller on the Cube moves the elevator to hold the fuselage's pitch at a target you set in CubeGUI |

Only one of them drives a servo at a time: while the script drives an output, the Cube ignores CubeGUI's commands to it. CubeGUI's **Who's in charge** panel shows which mode is active, and greys out any slider that has no effect.

You need it from level 2. It needs ArduPlane 4.5 or later: the Setup tab shows the version.

## Installing it

With CubeGUI, at level 2 or above, connected to the Cube over the Wi-Fi:

1. In the **Setup** tab, `SCR_ENABLE` shows "Needs changing", with 1 filled in. Click **Apply changes...** and confirm. CubeGUI then offers to reboot the Cube, which `SCR_ENABLE` needs: click **Reboot now**. (Or reboot later with **Reboot Cube...**, or by powering it off and on.) CubeGUI stays connected through the reboot.
2. In the Setup tab's **cubegui.lua on the Cube** box, click **Copy cubegui.lua to the Cube...** and confirm. CubeGUI copies `lua/cubegui.lua` to `APM/scripts` on the Cube's SD card over the Wi-Fi (about 12 kB, so a few seconds), then restarts the Cube's scripts.
3. On the Run tab, the **Who's in charge** panel should say **"Script running"** within a few seconds. If it says "no script heard", see Troubleshooting below.

Copy it again the same way whenever `lua/cubegui.lua` is updated. (CubeGUI uses MAVLink's file transfer protocol, the same as Mission Planner's MAVFtp window. Mission Planner still works for this too: **CONFIG** > **MAVFtp**, go to `APM` > `scripts`, right-click, **Upload**.)

This is the same as the guide's `servo_slew.lua` page (06a). If `servo_slew.lua` is still in `APM/scripts`, set `STEST_CHAN` to 0, or delete it, so the two don't fight over output 5.

## Setting it up

All of these are in CubeGUI's **Setup** tab at level 2 (and in Mission Planner's parameter list). Every servo stays on `SERVOn_FUNCTION = 0`.

| Parameter | What to set |
|---|---|
| `THR_FAILSAFE` | **2**, so the Cube notices when the transmitter's signal is lost and stops using the sticks. CubeGUI fills this in for you at level 2. |
| `RCn_OPTION` = **300** | On the channel of the **mode switch** (`n` is its channel number, e.g. `RC7_OPTION`): **low** RC, **high** CubeGUI, **middle** no change. With it high, CubeGUI can choose the closed loop. No channel with 300: CubeGUI chooses. |
| `RCn_OPTION` = **301** | On the channel of the **SAS switch** (pitch damping in RC mode): **low** off, **high** on, **middle** no change. None: CubeGUI chooses. |
| `CGUI_MODE_FUNC`, `CGUI_SAS_FUNC` | 300 and 301: the `RCn_OPTION` values the script looks for. Leave them alone unless another script uses 300 or 301. |
| `CGUI_M1_RC` / `CGUI_M1_OUT` ... `M4` | In RC mode, which stick drives which output. Defaults: channel 2 (elevator stick) drives output 5, channel 4 (rudder stick) drives output 6. |
| `CGUI_ELEV_OUT` | The elevator's output, for the closed loop and SAS. Default 5. |
| `CGUI_ENABLE` | 0 switches the script off: everything back to CubeGUI. |

To find which channel a stick or switch is on, open CubeGUI's **RC transmitter** panel, move it, and watch which bar moves. Then add that channel's `RCn_OPTION` in the Setup tab (type e.g. `RC7_OPTION` in **Add parameter**) and set it. A switch needs to go below 1200 at one end and above 1800 at the other.

The switches work the same way as in the guide's `avdasi2.lua` (page 06c), but **don't install both scripts**: they would fight over the servos.

**The transmitter's receiver should send no pulses when it loses the signal** (its failsafe setting), so the Cube can tell the signal has gone. Check your receiver's manual for how to set that.

### Which way is up

PWM above `SERVOn_TRIM` should move the surface nose-up (for the elevator). If it's the other way round, set **`SERVOn_REVERSED`** to 1 for that output. The script then reverses it in every mode. The script also keeps every output within its `SERVOn_MIN` and `SERVOn_MAX`, the same limits CubeGUI uses.

## The closed loop (level 3)

The controller works on the pitch error (target minus pitch) and the pitch rate, and moves the elevator from its trim position by:

> P × error + I (the error built up over time) − D × pitch rate

| Parameter | Default | What it does |
|---|---|---|
| `CGUI_KP` | 10 | P gain, µs of elevator per degree of error. More reacts harder; too much oscillates. |
| `CGUI_KI` | 2 | I gain, µs per degree-second. Removes a steady error, slowly. |
| `CGUI_KD` | 3 | D gain, µs per degree/second of pitch rate. Damps the motion. |
| `CGUI_IMAX` | 150 | The most the I term can add, in µs, so it can't wind up for ever |
| `CGUI_SAS_KD` | 3 | SAS damping in RC mode, µs per degree/second |

Change `CGUI_KP`, `CGUI_KI` and `CGUI_KD` in the **Closed-loop gains** box on the Run tab: type the new values and click **Apply...**, which shows the changes and asks first. The closed loop uses them straight away. (The others are in the Setup tab.)

The defaults are a guess at a safe start, not a tuned result: tune them on the rig, with the tunnel off first. CubeGUI's Simulated source runs the same controller with gains that suit the simulation, so you can try it at a desk.

## What it sends back

Five times a second, as values CubeGUI can plot and log (`logging.extraSignals`):

| Name | Meaning |
|---|---|
| `CG_MODE` | 0 CubeGUI, 1 RC, 2 closed loop |
| `CG_SAS` | 1 if SAS is on |
| `CG_TGT` | the pitch target, degrees |
| `CG_RC` | 1 if the transmitter's signal is valid |
| `CG_ELEV` | the elevator PWM the script is sending (0 in CubeGUI mode) |

It also writes a `CGUI` entry into the Cube's own log 10 times a second (mode, SAS, target, pitch, pitch rate, the P, I and D terms, and the elevator PWM), for studying the controller afterwards.

## Troubleshooting

- **"no script heard":** check `SCR_ENABLE` is 1 and you've rebooted since, and copy the script again from the Setup tab. Look in Mission Planner's Messages tab for a line starting "cubegui.lua" or "Lua".
- **The `CGUI_` parameters show "Not on this Cube":** the script hasn't run yet. As above.
- **The mode switch does nothing** (Who's in charge stays on CubeGUI with the switch low): check `RCn_OPTION = 300` is on the channel whose bar moves in the RC panel, and that the switch goes below 1200 and above 1800.
- **RC mode does nothing:** check `CG_RC` is 1 (the Who's in charge panel says "RC: OK"), and the `CGUI_Mn_RC` channels match the bars that move in the RC panel.
- **The elevator moves the wrong way in closed loop:** set `SERVO5_REVERSED` (for output 5) to 1.

## Tested

On ArduPilot's simulator (SITL), built from ArduPilot's own source on 2026-11-01, for both **ArduPlane 4.6.3** and the 4.8 development version. Tested: the three modes, both switches, CubeGUI's commands being ignored while the script drives, `SERVOn_MIN`/`MAX` and `REVERSED` being honoured, `CGUI_ENABLE`, and losing the RC signal with `THR_FAILSAFE = 2`; also CubeGUI end to end. Copying the script from CubeGUI was tested on SITL on 2026-11-03. **Not yet tested on a real Cube.** `tools/sitl/` has the tests.
