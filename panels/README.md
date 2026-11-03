# Panels

Each file here is one part of CubeGUI's Run tab: a plot, a slider, a button or a readout. The settings file (`config/cubegui.json`) lists which panels appear, under `plots` and `controls`.

| Panel | What it shows |
|---|---|
| `plotPanel.m` | A live plot of one signal: pitch, pitch rate, a servo, or a value from a Lua script |
| `servoPanel.m` | A slider, a number box and readouts for one servo |
| `valuePanel.m` | The latest value of a signal, in large type |
| `zeroAllButton.m` | A button that sends every servo to its trim position. The simplest one to copy. |
| `markerPanel.m` | Type a note and click Mark: it goes in both logs, at that moment |
| `modePanel.m` | Who's in charge of the servos (CubeGUI, the transmitter or the closed loop), and from level 3 the closed loop's controls. Needs `lua/cubegui.lua` on the Cube. |
| `rcPanel.m` | What the Cube receives from the transmitter, channel by channel |
| `calibrationPanel.m` | Steps a servo through its range while you measure the angle, then gives you a calibration table for the settings file |

To make your own, copy one of these, rename the copy (the file name and the name on its first line must match), and add it to the settings file. [docs/recipes.md](../docs/recipes.md) shows how, step by step, with examples.

Give your copies your own names, like `team3ServoPanel.m`, so an update to CubeGUI never overwrites them.
