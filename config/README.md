# CubeGUI settings

CubeGUI reads its settings from `cubegui.json` in this folder. Edit it in MATLAB's editor or any text editor, then restart CubeGUI. If something in it is wrong, CubeGUI won't start, and its message names the entry to fix.

There are ready-made settings files for the wind-tunnel tests (the "tunnel profiles"), at level 3: `fuselage.json`, `portwing.json` and `starboardwing.json`. The wing ones are placeholders until you know your outputs and sensors.

To keep a different set of settings, for example for another kit, copy the file and start CubeGUI with it:

```matlab
CubeGUI(ConfigFile="config/kit7.json")
```

## level

Which capability level to open at, from 0 to 3. Each level adds features: see the main README. Without it, everything is shown.

## connection

| Entry | What it is |
|---|---|
| `localPort` | The UDP port CubeGUI listens on. The Kahuna sends to 14550. |
| `cubeAddress` | The Kahuna's address: `192.168.4.1`. Use `127.0.0.1` for `tools/fake_cube.py`. |
| `cubePort` | The UDP port the Kahuna listens on: 14555. |

You can also change these in the window before you connect.

## logging

| Entry | What it is |
|---|---|
| `enabled` | `true` to start a log when you connect, `false` to wait until you click **Start** in the Logs panel. No quotes. Logging starts at level 1. |
| `folder` | Where log files go. `logs` means the `logs` folder inside CubeGUI. |
| `extraSignals` | Optional: values from Lua scripts to log, by name, each in its own column, e.g. `["FLAP_V", "CG_MODE"]`. |

## rates

| Entry | What it is |
|---|---|
| `telemetryHz` | How often CubeGUI asks the Cube for pitch and servo outputs: 20 a second. |
| `plotSeconds` | How many seconds the plots show. |

## plots and controls

The panels on the Run tab: `plots` down the left, `controls` down the right, in the order listed. Each entry names a file in the `panels` folder, plus anything that panel needs, e.g. `{"panel": "servoPanel", "servo": "Elevator"}`. An optional `"level"` makes it appear only from that level. [docs/recipes.md](../docs/recipes.md) explains each panel and how to make your own. Without these lists, CubeGUI shows a pitch plot, and a plot and a slider for each servo.

## servos

One `{ }` block per servo. A servo also needs a `servoPanel` in `controls` to get a slider, and a `plotPanel` in `plots` to be plotted.

| Entry | What it is |
|---|---|
| `name` | What to call it in the window and the log, e.g. `"Elevator"`. |
| `output` | The output it's plugged into: 5 for MAIN OUT 5. AUX OUT 1 is 9. |
| `units`, `range`, `mapping` | Optional: how the slider maps to PWM. See below. |

### PWM limits

Each servo's limits are the Cube's own parameters: `SERVOn_MIN`, `SERVOn_TRIM` and `SERVOn_MAX`, where n is the output number. Change them in CubeGUI's **Setup** tab, or in Mission Planner. CubeGUI reads them when it connects, and its sliders stay switched off until they've arrived.

- CubeGUI never sends anything below `SERVOn_MIN` or above `SERVOn_MAX`, whatever the slider says. The Cube itself doesn't check, so this matters.
- Zero all sends `SERVOn_TRIM`.
- All three must be between 1000 and 2000 µs, with MIN below TRIM below MAX. If they aren't, CubeGUI won't drive that servo at all until they're fixed.

The same parameters apply when the Cube drives the servo itself, for example from an RC transmitter, so one set of limits covers every way of moving it.

### Slider mappings

Without a `mapping`, the slider is the PWM itself, in microseconds (µs): it runs from the Cube's `SERVOn_MIN` to `SERVOn_MAX`, and starts at `SERVOn_TRIM`. That's the same number the Cube, Mission Planner and the step-by-step guide use.

If you'd rather work in percent of travel, use `"mapping": {"type": "percent"}`: 0 % is `SERVOn_TRIM`, +100 % is `SERVOn_MAX` and −100 % is `SERVOn_MIN`.

Once you've calibrated a surface, measuring its deflection at a few PWM values, you can make the slider work in degrees. The easiest way is a table: CubeGUI draws straight lines between your points.

```json
{
  "name": "Elevator",
  "output": 5,
  "units": "deg",
  "mapping": {
    "type": "table",
    "points": [[-20, 1150], [-10, 1320], [0, 1500], [10, 1690], [20, 1870]]
  }
}
```

Each point is `[value, pwm]`, in increasing order of value. The slider runs from the first value to the last. PWM values beyond the Cube's `SERVOn_MIN` and `SERVOn_MAX` are held at those limits.

You can use a formula instead. These also need `"range": [low, high]`, the slider's ends in your units.

| `type` | Formula | Entries |
|---|---|---|
| `linear` | pwm = m × x + c | `"m"`, `"c"` |
| `exponential` | pwm = a × e^(b × x) + c | `"a"`, `"b"`, `"c"` |
| `custom` | anything in x | `"expression"`, e.g. `"1500 + 18*x + 0.05*x^3"` |

A custom expression can use `x`, numbers, `+ - * / ^`, brackets, `exp`, `log`, `sqrt`, `sin`, `cos`, `tan`, `abs` and `pi`.

Whatever the mapping, it must always go up (or always go down) across its range, or CubeGUI won't accept it. One PWM value can't mean two different positions.
