# Design decisions

Decisions made while building CubeGUI, and why. Earlier ones are in [requirements.md](requirements.md), sections 4 and 5. Newest first.

## 2026-11-04, later still: text that doesn't fit

Fixed what screenshots at 1180 × 780 and 1240 × 630 showed cut off, rather than relying on hover text: the Setup tab's right-hand column scrolls instead of squashing (the Lua values table was down to less than a row), the Firmware over USB note is shorter, the "On the Cube" column is wider, servo plots mark only MIN, TRIM and MAX, and over USB the port's drop-down uses the UDP boxes' space. Hover text (`Tooltip`) is the back-up for messages whose length can't be known in advance, such as error messages. The cubegui.lua box no longer says "over the Wi-Fi", since USB works too.

Then Robin found the MAVLink port missing from the list, and the other port "probably MAVLink": a second CubeGUI window was holding it, and `serialportlist("available")` leaves out ports in use. Now every port is listed, one in use is labelled so and never guessed, and the status line says why. The calibration panel's text was also cut off; it's shorter, with the rest on hover.

## 2026-11-04, later: USB, flashing and Reset move into level 1; level 4 goes

Robin tested USB, flashing and Reset on Windows and on a Mac with a real Cube, and decided to release them in level 1. Level 4 is removed, so the levels are 0 to 3 again, as agreed with Steve.

- **USB in level 1** because the Cube's own log comes off it about 70 times faster than over the Wi-Fi (about 280 kB/s against 4 kB/s), with no setup. The Wi-Fi stays the way to connect in the tunnel: a cable to a pivoting fuselage would add stiffness and friction about the pitch axis.
- **Flash ArduPlane and Reset to a fresh Cube in level 1**, in the Setup tab, which had room. Flashing never touches the bootloader, so a failed flash can be tried again. Reset erases everything, calibrations included, so its confirmation says so and the README says the step-by-step guide's calibrations still need a ground station.
- **The sources are now "Cube (Wi-Fi)" and "Cube (USB)"**, so the choice reads as a pair. On MATLAB before R2026b, Cube (USB) isn't offered at all, rather than failing when Connect is clicked.
- **Over USB, CubeGUI reconnects by itself after a reboot.** Robin found Reset worked, but CubeGUI had to be disconnected and connected again: the Cube's USB device goes away while it reboots, and the old connection never hears the new one. Now the port is opened again once it's back (`CubeSource.reopenSerial`).

## 2026-11-04: level 4, USB and firmware (a preview)

**Why:** Mission Planner runs badly on a Mac, and the course can't support QGroundControl. A piece of CubeGUI is something it can support. Robin asked for it as a level of its own, so the basic version doesn't grow. It may be shipped differently later.

**USB through UAV Toolbox's serial MAVLink**, which needs R2026b. A fallback for R2026a (reading bytes with `serialport` and decoding them by hand) was left out until the lab laptops' release is known.

**Firmware from `.abin` files, not `.apj`.** The `.apj` that Mission Planner uses holds the image zlib-compressed, and MATLAB R2026 has no Java, so it has no built-in way to uncompress it. ArduPilot publishes an `.abin` beside each `.apj`, with the same image uncompressed (checked byte for byte for the Cube Orange+). CubeGUI downloads the right one for the board the bootloader reports, or uses a file the student chooses.

**USB alongside the bench supply is fine** (Robin), as long as it's plugged in correctly: the servos don't draw from USB, because the servo rail is powered from the UBEC on AUX OUT 1. So **Cube (USB)** can be used for test runs, not just set-up jobs.

**`SERIAL1_*` stay read-only, over USB too** (Robin): changing the telemetry link's settings from CubeGUI wouldn't gain anything.

**After Robin's first test on Windows and a Mac (same day):**
- **The window fits the screen.** With the display at 150 %, the title bar was off the top of the screen and the window couldn't be moved.
- **Over USB the log download doesn't warn about the Wi-Fi.**
- **The erase shows it's busy**, with the seconds so far: it can't say how far it has got, and the bar sat at 0 for about 30 s. Up to 90 s is now allowed; uploader.py's 20 s would be too tight.
- **The USB ports are labelled MAVLink or not**, by listening for a heartbeat. The second port is SLCAN (ArduPilot's hwdef). If no heartbeat is heard, the lowest-numbered is "probably MAVLink", as Robin suggested.
- **Later the same day, after a test on a real Cube on Robin's Mac:** the list showed Robin's Bluetooth speakers and chose one (`/dev/cu.JBLCharge5` ends in 5, so it counted as the lowest number), and listening with `serialport` heard nothing from the Cube at all. Now a Mac lists only `/dev/cu.usbmodem...` ports (Linux only `/dev/ttyACM...`; Windows all of them), and the listening is done with `mavlinkio`, which heard the Cube at once. Still only listening, never sending, so the SLCAN port and anything else plugged in are left alone; an earlier idea, writing a byte to wake each port, was dropped for that reason. Not yet tried on Windows.
- **Reset to a fresh Cube.** Robin found that flashing kept the parameters (and the script, still on the SD card, still running because `SCR_ENABLE` was kept). Reset sets `FORMAT_VERSION` to 0 and reboots, which makes ArduPilot erase all its settings as it starts. That's the same thing "flash Sub, then Plane" achieves, without flashing. Scripts aren't deleted: with `SCR_ENABLE` back at 0 they don't run.

**Flashing in a button's callback with a progress dialog**, not in a timer. It's a minute or so, and nothing else needs the Cube meanwhile.

**Tested without a Cube.**
- The uploader was tested against a pretend bootloader written in MATLAB (`tests/FakeBootloader.m`). A Python one on a pseudo serial port didn't work, because MATLAB's `serialport` won't open one on a Mac.
- UAV Toolbox's serial connection does open a pseudo port, so the USB connection was tested end to end against SITL through `tools/sitl/usb_relay.py`.
- Neither has run on a real Cube yet.

## 2026-11-03: after Robin's meeting with Steve

Robin brought back a list of changes from the meeting and their own testing, and decided these:

**Four levels, numbered from 0.** Six was too many to explain. Now 0 Simulate, 1 Connect and log (the old 2 and 3 together), 2 RC (old 4), 3 Closed loop (old 5). The old level 6 unlocked nothing in the program, so the tunnel settings files (`fuselage.json` and the wings) aren't a level any more: they're "tunnel profiles" at level 3, shipped when the wing teams' outputs are known. The entries below this one use the old numbers.

**Sliders are PWM in µs by default**, not percent. A slider runs from the Cube's `SERVOn_MIN` to `SERVOn_MAX` and starts at `SERVOn_TRIM`. Students then see the same number as the Cube, Mission Planner and the guide, and percent hid what was actually sent. Degrees come from a calibration table, as before; `"mapping": {"type": "percent"}` still gives percent. A PWM slider's ends depend on the Cube's limits, which arrive after connecting, so `servoPanel` and `plotPanel` now follow them.

**Logs started and stopped from the Run tab.** A Logs panel (part of the engine, from level 1) has Start and Stop for CubeGUI's CSV log and for the Cube's own log. ArduPilot has no command to start or stop logging without arming, and Lua scripts can't do it either (checked: the `logger` binding only writes; `AP_Logger.cpp`, `bindings.desc`). So CubeGUI starts and stops the Cube's log by setting `LOG_DISARMED` to 1 or 0, after a confirmation, like every parameter write. Stopping pauses the log rather than closing the file (`AP_Logger_Backend.cpp`: writes stop when `log_while_disarmed()` is false, but the file stays open); a new file starts at each power-up, and after a download. Both seen on SITL. The Setup tab no longer fills in `LOG_DISARMED = 1`, as that would start the log behind the student's back.

**Downloading the Cube's log over the Wi-Fi**, from the Logs panel, once the log is stopped. It uses MAVLink's log protocol (`LOG_REQUEST_LIST`, `LOG_REQUEST_DATA`, `LOG_REQUEST_END`), with `engine/LogDownload.m` asking again for any gaps. It's slow: the Kahuna's link runs at 57600 baud, and ArduPilot sends one 90-byte `LOG_DATA` at a time on a link without flow control (`AP_Logger_MAVLinkLogTransfer.cpp`). So the dialog gives an estimate at 4 kB/s, and the docs point to USB first. Robin timed it on a kit the same day: 0.5 MB (ten seconds of logging) in 2 minutes 3 seconds, about 4 kB/s, so a minute of logging takes about 12 minutes. It stays, as the slow option; USB is the expected way.

**Installing `cubegui.lua` from CubeGUI**, so students don't need Mission Planner for it. The Setup tab (level 2) copies the file to `/APM/scripts` with MAVLink's file transfer protocol (MAVFTP), then restarts the Cube's scripts (`MAV_CMD_SCRIPTING`). UAV Toolbox only has MAVFTP from R2026b (`ftpMicroservice`), so `engine/FtpUpload.m` does it by hand, which also works on R2026a. ArduPilot's side was checked in `GCS_FTP.cpp`: one file open per session (so it resets sessions first), and a repeated sequence number gets the last answer again (so a lost message can be re-sent safely).

**PID gains in boxes with Apply**, on the Run tab at level 3. Live sliders were the alternative, but they'd write a saved parameter on every movement without asking. Panels can't write parameters, by design, so the gains box is part of the engine, and Apply lists the changes and asks first.

**The closed loop handed back below level 2.** A window at level 0 or 1 has no mode controls, so if the Cube's script was left in closed loop (from a level 3 window, say), the elevator could never be taken back. Now `Cube.tick` asks the script for CubeGUI mode, once a second, whenever it hears it in closed loop below level 2. Robin also asked whether the script itself should give up the closed loop when CubeGUI goes quiet; that's still open.

**The safety switch says "Safety switch ON" or "OFF" in one label**, in bold, with the panel's title removed. "On" on its own, under a "Safety switch" title, could be read as "servos on".

**Calibration's Back works after Finished.** It used to move the servo but leave Record switched off. Now Back measures the last step again, and Record comes back on.

**Not for flight, and how AI was used, said plainly.** The README, the Lua README and the site page say CubeGUI is lightly tested and suitable only for careful wind-tunnel and bench testing. The README says it was written with Claude and what that means. `AGENTS.md` tells students' AI assistants to teach as they help, to keep the safety rules, and to keep reminding students it's not for flight. `CLAUDE.md` points to it.

**MIT licence**, in `LICENSE`, as Robin decided.

## 2026-11-03, later: after Robin's first test of the new version

**A Reboot Cube button, and a reboot offered after `SCR_ENABLE`.** Students can't power-cycle a Cube inside the wind tunnel. Writing `SCR_ENABLE` or `BRD_SAFETY_DEFLT` now asks "Reboot the Cube now?" after the usual confirmation, and reboots only once the Cube has confirmed the new value. ArduPilot also saves pending parameters before rebooting, but waiting covers a write lost on the Wi-Fi.

**Calibration in its own window.** The panel on the Run tab was too small, and text was cut off. The window has the steps as a table, a plot of the up and down sweeps, the result with a Copy button, and what to do next. Students are asked to paste the table into their settings file, check an angle or two by measuring, approach test angles from one side if the hysteresis matters, and calibrate again after changing the linkage.

**Levels 2 and 3 ship as previews.** Robin asked whether to release one level at a time or ship everything. Both, in effect: all the code ships, so nothing has to be taken out and put back, and updating is one pull. But levels 2 and 3 are marked "preview: not released yet" in the window and the docs, and aren't supported until released. `CubeGUI` opens at level 1. Each level's `released` flag in `levels.m` is what changes at a release.

**The site page is a signpost, not a copy.** The step-by-step guide gets one short page, stage 7 (`07-cubegui.md`, with the sensor pages moving back one), saying what CubeGUI is, what it needs, and where its own README and videos are. CubeGUI's documentation stays in its repository, where it changes with the code, so the guide never holds a second, out-of-date copy. The draft is `docs/avdasi2-site-page.md`.

**`requirements.md` moved into `docs/`.** It's the spec CubeGUI was built to, for maintainers; students don't need it at the top level.

## 2026-11-01: the script's switches found by RCn_OPTION, as in avdasi2.lua

The guide's page 06c (Sid Reid's `avdasi2.lua`) does a similar handover with a transmitter switch. Robin compared the two scripts with the team, and agreed to take its way of finding the switches:

**The switches are found by `RCn_OPTION`** (300 for the mode switch, 301 for SAS), not by a channel number. This is ArduPilot's usual way, and it means the two scripts are set up the same way on the transmitter. `CGUI_MODE_CH` and `CGUI_SAS_CH` are gone; `CGUI_MODE_FUNC` and `CGUI_SAS_FUNC` (default 300 and 301) take new parameter indices, so a value stored under the old ones can't carry over.

**The same positions as avdasi2.lua:** mode switch low RC, high CubeGUI, middle no change; SAS switch low off, high on, middle no change. So a 2-position switch works, and an ambiguous middle position never changes anything. The transmitter can no longer choose the closed loop itself; CubeGUI's **Closed loop** button does that, with the switch high.

**The position is read straight away** (`rc:find_channel_for_option` and `get_aux_switch_pos`), rather than with `rc:get_aux_cached`, which stays empty until the switch has moved after boot (`RC_Channel.cpp`, `init_aux_function`). On RC loss the switch counts as absent, so RC mode ends.

## 2026-11-01: levels 4 to 6 (built for review, not yet agreed)

Robin asked me to research and build what was concrete while they were away, uncommitted, for review. The design was reviewed as a proposal (in the development history, not in this repository). The decisions:

**One Lua script takes over outputs, rather than switching `SERVOn_FUNCTION` between modes.** Every servo stays on function 0. In RC and closed-loop modes, `cubegui.lua` holds the outputs it needs with `set_output_pwm_chan_timeout`, and ArduPilot then ignores CubeGUI's `DO_SET_SERVO` for them, so two things can never drive one servo. The alternative, switching to RC passthrough functions (1, 51–66), would need a parameter write (with confirmation) at every mode change, and would bring ArduPilot's own mode logic into play.

**CubeGUI talks to the script with `MAV_CMD_USER_1`**, decoded by hand in the script, rather than by writing parameters. A mode change or pitch target sent as a parameter would need a confirmation each time (rule 13) and would be saved to the Cube's storage on every slider move. Hand-decoding the one message with `string.unpack` saves students uploading ArduPilot's MAVLink module files.

**The script reports who's in charge** (`CG_MODE` and the rest), because the Cube still acknowledges `DO_SET_SERVO` commands it then ignores, so CubeGUI couldn't tell from the replies.

**`THR_FAILSAFE = 2` from level 4.** With 0, ArduPlane never declares RC lost, so a script reading the sticks would keep using their last positions after the signal went. 2 detects the loss without a failsafe action. (This settles the "revisit at level 4" note from 31 October.)

**A transmitter switch outranks CubeGUI**, but in one position CubeGUI chooses, so the pilot can always take over and hand back with one flick. (Positions changed later the same day: see above.)

**Closed loop holds its last target if CubeGUI goes quiet**, rather than dropping back to CubeGUI mode, so the rig keeps flying steadily. That's a question for Robin.

**The Simulated source behaves like the script**, so closed loop can be tried at a desk. Its gains are tuned for the simulation. The script's defaults (10, 2, 3) are marked GUESS until tuned on the rig.

**Run markers go to both logs**, as `STATUSTEXT` (which ArduPilot writes to its own log as `MSG`) and in a `marker` column placed by Cube time, so the two logs and students' notes can be lined up.

**A calibration helper, but no hysteresis handling yet.** `calibrationPanel` steps the PWM up and back down and records the angle each way, so it measures the hysteresis as well as giving the table. Whether to add "approach from one side" (roadmap 7.4) can then be decided from real numbers, not guessed. `calibrationTable` refuses angles that don't keep rising (or keep falling) with PWM, because the table mapping must be monotonic.

**ArduPlane versions:** the script needs 4.5 or later. It works around two differences between 4.6.3 and 4.8-dev: `get_pitch` against `get_pitch_rad`, and the argument order of `mavlink:init`. It has been tested on SITL running both 4.6.3 and 4.8-dev, not yet on a real Cube.

## 2026-10-31: logged commands placed by Cube time

In Robin's second real-Cube log, the `_out_us` columns changed up to 2.7 s after the `_cmd_us` columns, although the Cube carried out every command. The logger put each command in the first row to *arrive* after it was sent, and in the VM samples arrived up to 7 s late, so commands landed seconds early in Cube time. Now the logger estimates the laptop-to-Cube clock difference as the smallest gap seen between a sample's Cube time and its arrival, converts each command's send time to Cube time, and puts it in the first row at or after that. The estimate starts again after a reboot. It can only be as good as the least-delayed sample so far, so the first few seconds of a log may still be slightly off.

## 2026-10-31: THR_FAILSAFE is no longer required

Robin pointed out that the RC failsafe is unnecessary when the Cube is never armed. Checked in ArduPilot: a disarmed Plane that has never heard an RC receiver skips the RC failsafe check entirely (`ArduPlane/radio.cpp`, `allow_failsafe_bypass`), and a failsafe action only changes the flight mode, which doesn't touch outputs with `SERVOn_FUNCTION = 0`. `THR_FAILSAFE = 0` matters only for arming without RC (a pre-arm check in `AP_Arming_Plane.cpp`), which is why the guide sets it. So the Setup tab still shows it, with a note, but accepts any value. To revisit at level 4: with an RC receiver in use, `THR_FAILSAFE = 1` is probably the safer setting, because the Cube then ignores RC inputs if the signal is lost.

## 2026-10-31: the engine/panel split and levels (roadmap 7.1 and 7.2)

Built as proposed (option A of a design proposal), which Robin chose on 2026-10-23, with these decisions along the way:

**Plain `engine/` and `panels/` folders, not a `+cubegui` package.** No new syntax for students, and the tutor's Python comparisons stay simple. The protection is that panels only get `cube`.

**Servo state moved into `Cube`.** The limits, the mapping rebuilt from them, the last target and the rate limit all used to live in `ServoControl` and the window. They're now in `Cube`, so every panel (a student's own slider included) gets the same safety rules, and `servoPanel` is a plain function. The rate limit holds back a too-soon command and sends it on the next tick, so the final position is never lost.

**A broken panel is replaced by a red message in its own space**, not just a status-line message: in testing, the next status message ("Connected to Simulated") overwrote the error. The message names the panel's file and the line in it.

**Window-only methods on `Cube` are `Hidden`, not access-restricted.** MATLAB's restricted access (`Access = {?CubeGuiApp, ...}`) doesn't let function-based tests call them. Hidden keeps them out of students' tab completion, which is what matters.

**Levels hide; they don't lock.** One codebase, one `level` setting, as proposed. Level 1 unparents the Setup tab rather than not building it, so the rest of the window needn't check for it. Robin asked for parameter writing from level 2, with the recommended parameters changing per level: each entry in `setupParameters` has a level.

**Level 3 recommends `LOG_DISARMED = 1`**, so the Cube keeps its own flight log while disarmed, which is how it's always used here. 3 is rejected as not OK: it throws the log away if the Cube never arms (`AP_Logger.cpp`).

**The controls column scrolls** when its panels don't fit, rather than CubeGUI guessing a window height that suits every laptop.

**Pitch rate is logged** (`pitch_rate_dps`), because the unit's spec (3.3.3) asks for pitch angle and rate. It comes from `ATTITUDE.pitchspeed`.

**A finding for the recipes:** the Cube reports the PWM it's sending, which jumps straight to the new value, not where the servo physically is. A landing-gear "moving" status therefore has to be estimated from the gear's travel time (recipe 7), or measured with a sensor.

## 2026-10-23: servo limits from the Cube, and lessons from the first real log

**The servo limits are the Cube's `SERVOn_MIN`, `_TRIM` and `_MAX`** (Robin's decision). In the first real-Cube test, Robin changed `SERVO7_MAX` to 1800 in the Setup tab, but 100 % still sent 1900, because CubeGUI took its limits from its own settings file. The Cube didn't step in either: on an output with function 0, ArduPilot sends `DO_SET_SERVO`'s PWM straight out (`AP_ServoRelayEvents.cpp`, `do_set_servo`, then `SRV_Channel::set_output_pwm`), and the log confirmed 1900 went out. Two sets of limits would also disagree once RC and Lua drive the same servos (roadmap 7.5), and those use the Cube's parameters. So CubeGUI now reads them on connect and follows any change. The sliders stay off until they arrive. The settings file's old `minPwm`/`trimPwm`/`maxPwm` entries are refused with a message, rather than quietly ignored, so nobody edits them expecting an effect.

**Limits outside 1000–2000 µs are refused, not clamped** (Robin's choice). A typo like `SERVO6_MAX = 2100` switches that servo off, with a message saying which parameter to fix, instead of quietly driving it to 2000.

**Late samples are skipped.** The real log had samples up to 7 s late and out of order (probably the VM's networking plus Wi-Fi). Each backwards jump was treated as a reboot: the buffers were emptied and the CSV got repeated rows. Now a sample older than the newest is skipped. A reboot needs the clock to be more than a second back and either under a minute (just booted) or staying behind for 3 s. The second case covers a Cube that rebooted while CubeGUI couldn't hear it. Skipping loses those late samples from the CSV; the Cube's own flight log still has them.

**The output clock is lined up using the pitch clock.** The Cube had been on for 75 minutes, so `SERVO_OUTPUT_RAW`'s 32-bit microsecond clock had already wrapped before CubeGUI connected, and Wednesday's "within a minute of the top" rule couldn't see it. `ATTITUDE`'s millisecond clock doesn't wrap for 49 days, so it now says how many wraps there have been. That replaces the earlier rule.

**Plot interactions are off.** Profiling showed MATLAB spending 2.3 s setting up zoom and pan on the plots the first time they drew data, holding up every timer. CubeGUI's plots don't need them.

## 2026-10-21: milestone 8 robustness

**Telling a reboot from the output clock wrapping.** `SERVO_OUTPUT_RAW`'s clock is a 32-bit count of microseconds (ArduPilot fills it from `AP_HAL::micros()`: `GCS_Common.cpp`, `send_servo_output_raw`), so it wraps to zero every 71.6 minutes. CubeGUI used to count any jump backwards of more than half the range as a wrap. A Cube rebooted after 36 minutes or more looked like that, so the outputs were stamped about 4,295 s ahead of the pitch, and the log's `_out_us` columns were blank for up to 71 minutes afterwards. Now a jump only counts as a wrap if the clock was within a minute of the top and is now within a minute of zero. Anything else is a reboot. The alternative, working out the wraps from `ATTITUDE`'s millisecond clock, was rejected as harder to explain, and it ties two messages together. (Superseded on 2026-10-23: the real Cube showed the rule misses a wrap that happened before CubeGUI connected, so the pitch clock is used after all. See above.)

**One reboot counter, in `Telemetry`.** The pitch buffer spots a reboot and adds one to `Telemetry.RebootCount`. The logger and the window both read that count, instead of each comparing clocks their own way. On a reboot the window says so (the safety switch is on again after every reboot), and reads the parameters and version again, because a reboot may follow a re-flash.

**Port in use, by number as well as text.** MATLAB's UDP error passes on the operating system's error number (`[system:48 ...]` on macOS, seen). Matching the number as well as the English text (48 macOS, 98 Linux, 10048 Windows) covers Windows set to another language. The Windows number and text come from Microsoft's documentation and are marked GUESS until they've been seen from MATLAB.

**Forget the source before shutting it down.** `CubeGuiApp.disconnect` used to delete the source and then clear `obj.Source`. Shutting down the network can let the redraw timer run in between, and once (in about 40 quick reconnects) it found a half-deleted source. Clearing `obj.Source` first means the redraw sees "not connected" instead. Seen once and not reproduced since; the fix follows from reading the code.
