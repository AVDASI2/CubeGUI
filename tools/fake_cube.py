#!/usr/bin/env python3
"""A pretend Cube Orange+ for testing CubeGUI without any hardware.

It talks MAVLink over UDP the way the Cube does through the Kahuna Wi-Fi
board: it sends telemetry to a ground station's UDP port (14550 by default)
from its own port 14555, and listens on 14555 for commands coming back. The
Kahuna's firmware uses the same two ports.

What it sends:
    HEARTBEAT          1 Hz, as an ArduPlane fixed-wing autopilot
    ATTITUDE           pitch swings back and forth like the fuselage on its pivot
    SERVO_OUTPUT_RAW   the PWM on each output, echoing DO_SET_SERVO commands
    SYSTEM_TIME        1 Hz
    NAMED_VALUE_FLOAT  a "DEMO" value, standing in for a Lua script
    RADIO_STATUS       1 Hz from component 240, as the Kahuna itself does
    SYS_STATUS         1 Hz; its "motor outputs" flag shows the safety switch state
    AUTOPILOT_VERSION  when asked for, with made-up version numbers

What it answers:
    MAV_CMD_DO_SET_SERVO, MAV_CMD_SET_MESSAGE_INTERVAL, MAV_CMD_REQUEST_MESSAGE,
    MAV_CMD_DO_SET_SAFETY_SWITCH_STATE (or, with --old-firmware, only the
    older SET_MODE way of setting the safety switch),
    MAV_CMD_COMPONENT_ARM_DISARM (with a loud warning), and parameter
    requests (PARAM_REQUEST_LIST, PARAM_REQUEST_READ, PARAM_SET).

Everything it receives from the ground station is printed, so you can see
exactly what CubeGUI is sending.

It is a test tool, not a simulator. Where it has to guess at how a real Cube
behaves, the guess is marked "GUESS" in the code.

Usage:
    python tools/fake_cube.py                    # send to 127.0.0.1:14550
    python tools/fake_cube.py --target 192.168.1.20:14550
    python tools/fake_cube.py --target 127.0.0.1:14560 --listen-port 14565
    python tools/fake_cube.py --verbose          # also print every message received
    python tools/fake_cube.py --uptime 4290      # as if booted 71.5 minutes ago
"""

import argparse
import math
import os
import random
import sys
import time

# ArduPilot talks MAVLink 2 on its telemetry ports by default. This has to be
# set before pymavlink is imported.
os.environ.setdefault("MAVLINK20", "1")

from pymavlink import mavutil  # noqa: E402

mavlink = mavutil.mavlink

# Message IDs used below, so the code reads by name.
MSG_IDS = {
    "HEARTBEAT": mavlink.MAVLINK_MSG_ID_HEARTBEAT,
    "ATTITUDE": mavlink.MAVLINK_MSG_ID_ATTITUDE,
    "SERVO_OUTPUT_RAW": mavlink.MAVLINK_MSG_ID_SERVO_OUTPUT_RAW,
    "SYSTEM_TIME": mavlink.MAVLINK_MSG_ID_SYSTEM_TIME,
    "NAMED_VALUE_FLOAT": mavlink.MAVLINK_MSG_ID_NAMED_VALUE_FLOAT,
    "AUTOPILOT_VERSION": mavlink.MAVLINK_MSG_ID_AUTOPILOT_VERSION,
    "RADIO_STATUS": mavlink.MAVLINK_MSG_ID_RADIO_STATUS,
    "SYS_STATUS": mavlink.MAVLINK_MSG_ID_SYS_STATUS,
}
MSG_NAMES = {v: k for k, v in MSG_IDS.items()}

# Starting rates in Hz, before the ground station asks for anything else.
# GUESS: low rates, roughly like ArduPlane's defaults on a telemetry port, so
# that CubeGUI has to ask for 20 Hz with SET_MESSAGE_INTERVAL just as it will
# with a real Cube.
DEFAULT_RATES_HZ = {
    "HEARTBEAT": 1.0,
    "ATTITUDE": 4.0,
    "SERVO_OUTPUT_RAW": 2.0,
    "SYSTEM_TIME": 1.0,
    "NAMED_VALUE_FLOAT": 1.0,
    "RADIO_STATUS": 1.0,  # GUESS at how often the Kahuna sends it
    "SYS_STATUS": 1.0,
}

# The pretend firmware version: ArduPlane 4.6.2, official release.
FW_MAJOR, FW_MINOR, FW_PATCH = 4, 6, 2
FW_TYPE_OFFICIAL = 255

# Pitch motion: a slow swing about the pivot, plus a little sensor noise.
PITCH_AMPLITUDE_DEG = 8.0
PITCH_PERIOD_S = 4.0
PITCH_NOISE_DEG = 0.2

# Output functions that DO_SET_SERVO is allowed to drive: 0 (disabled),
# 1 (RCPassThru) and 51 to 66 (RCIN1 to RCIN16). Anything else is "in use".
FREE_FUNCTIONS = {0, 1} | set(range(51, 67))

NUM_OUTPUTS = 16

# The Kahuna Wi-Fi bridge identifies itself as this component
# (MAV_COMP_ID_UDP_BRIDGE). The autopilot is component 1.
BRIDGE_COMPONENT = 240

# MAV_CMD_DO_SET_SAFETY_SWITCH_STATE, written out in case the installed
# pymavlink is too old to know it.
CMD_SET_SAFETY_SWITCH_STATE = 5300

# SYS_STATUS bit ArduPilot sets while the safety switch is off (GCS.cpp).
SENSOR_MOTOR_OUTPUTS = 0x8000
# SET_MODE with base_mode exactly this sets the safety switch (GCS_Common.cpp).
MODE_FLAG_DECODE_POSITION_SAFETY = 128


def make_params(fresh=False):
    """The parameters the fake Cube knows about, as {name: (value, type)}.

    These match the state the AVDASI 2 step-by-step guide leaves the Cube in:
    ArduPlane defaults, then THR_FAILSAFE = 0. With fresh=True, it's a Cube
    straight after flashing, before the guide's changes (THR_FAILSAFE = 1),
    which is handy for testing CubeGUI's Setup tab. The real Cube has well
    over a thousand parameters; these are only the ones CubeGUI reads.
    """
    int8 = mavlink.MAV_PARAM_TYPE_INT8
    int16 = mavlink.MAV_PARAM_TYPE_INT16
    params = {
        "SYSID_THISMAV": (1, int8),
        "THR_FAILSAFE": (1 if fresh else 0, int8),  # ArduPlane default is 1; the guide sets 0
        "SCR_ENABLE": (0, int8),
        "LOG_DISARMED": (0, int8),
        "BRD_SAFETY_DEFLT": (1, int8),
        "ARMING_CHECK": (1, int8),
        "BRD_SAFETY_MASK": (0, mavlink.MAV_PARAM_TYPE_INT32),
        "SERIAL1_PROTOCOL": (2, int8),
        "SERIAL1_BAUD": (57, mavlink.MAV_PARAM_TYPE_INT32),
    }
    # ArduPlane's default output functions: 1 aileron, 2 elevator,
    # 3 throttle, 4 rudder, everything else disabled.
    default_functions = {1: 4, 2: 19, 3: 70, 4: 21}
    for n in range(1, NUM_OUTPUTS + 1):
        params[f"SERVO{n}_FUNCTION"] = (default_functions.get(n, 0), int16)
        params[f"SERVO{n}_MIN"] = (1100, int16)
        params[f"SERVO{n}_TRIM"] = (1500, int16)
        params[f"SERVO{n}_MAX"] = (1900, int16)
        params[f"SERVO{n}_REVERSED"] = (0, int8)
    return params


class Colour:
    """ANSI colours for the terminal. Turned off with --no-colour."""

    on = True

    @classmethod
    def wrap(cls, code, text):
        return f"\033[{code}m{text}\033[0m" if cls.on else text

    @classmethod
    def red(cls, text):
        return cls.wrap("1;31", text)

    @classmethod
    def green(cls, text):
        return cls.wrap("32", text)

    @classmethod
    def yellow(cls, text):
        return cls.wrap("33", text)

    @classmethod
    def dim(cls, text):
        return cls.wrap("2", text)


class FakeCube:
    def __init__(self, target, listen_port, sysid, verbose, fresh=False, old_firmware=False,
                 uptime=0.0):
        self.target = target
        self.listen_port = listen_port
        self.old_firmware = old_firmware
        self.verbose = verbose
        self.conn = mavutil.mavlink_connection(
            f"udpout:{target}",
            source_system=sysid,
            source_component=mavlink.MAV_COMP_ID_AUTOPILOT1,
            dialect="ardupilotmega",
        )
        # Send from, and listen on, a fixed port, as the Kahuna does. Without
        # this the operating system would pick a random port. Binding has to
        # happen before anything is sent.
        try:
            self.conn.port.bind(("0.0.0.0", listen_port))
        except OSError as err:
            sys.exit(f"fake_cube couldn't use UDP port {listen_port} ({err}). "
                     f"Is another fake_cube running? Try --listen-port.")
        self.mav = self.conn.mav
        # --uptime pretends the Cube booted that many seconds ago, to test long
        # sessions: SERVO_OUTPUT_RAW's microsecond clock wraps after 71.6 minutes.
        self.boot = time.monotonic() - uptime

        self.params = make_params(fresh)
        self.param_names = list(self.params)  # fixed order gives each an index

        # GUESS: before a servo is commanded, report its trim value.
        self.pwm = [self.params[f"SERVO{n}_TRIM"][0] for n in range(1, NUM_OUTPUTS + 1)]

        self.armed = False
        self.safety_on = True  # BRD_SAFETY_DEFLT = 1: safety on after boot
        self.rates_hz = dict(DEFAULT_RATES_HZ)
        self.next_send = {name: 0.0 for name in self.rates_hz}

        # GUESS: with no GPS, the Cube doesn't know the real date and time,
        # so SYSTEM_TIME carries 0 until a ground station sends its own
        # SYSTEM_TIME. Unverified on real hardware.
        self.unix_offset_us = None

        self.gcs_seen = False
        self.last_gcs_heartbeat = None
        self.sent_counts = {name: 0 for name in self.rates_hz}
        self.next_summary = 5.0

    # ---- helpers -----------------------------------------------------------

    def now(self):
        """Seconds since the fake Cube 'booted'."""
        return time.monotonic() - self.boot

    def time_boot_ms(self):
        return int(self.now() * 1000) & 0xFFFFFFFF

    def log(self, text):
        print(f"{Colour.dim(f'[{self.now():8.2f}]')} {text}", flush=True)

    def send(self, fn, *args):
        """Send a message, ignoring network errors so the loop keeps going.

        If nothing is listening on the target port yet, some systems report
        'connection refused'. A real Cube doesn't care, so neither do we.
        """
        try:
            fn(*args)
        except OSError as err:
            if self.verbose:
                self.log(Colour.yellow(f"send failed: {err}"))

    # ---- periodic telemetry --------------------------------------------------

    def send_heartbeat(self):
        base_mode = mavlink.MAV_MODE_FLAG_CUSTOM_MODE_ENABLED
        if self.armed:
            base_mode |= mavlink.MAV_MODE_FLAG_SAFETY_ARMED
        self.send(
            self.mav.heartbeat_send,
            mavlink.MAV_TYPE_FIXED_WING,
            mavlink.MAV_AUTOPILOT_ARDUPILOTMEGA,
            base_mode,
            0,  # custom_mode 0 is MANUAL in ArduPlane
            mavlink.MAV_STATE_ACTIVE if self.armed else mavlink.MAV_STATE_STANDBY,
        )

    def send_attitude(self):
        t = self.now()
        w = 2 * math.pi / PITCH_PERIOD_S
        pitch_deg = PITCH_AMPLITUDE_DEG * math.sin(w * t) + random.gauss(0, PITCH_NOISE_DEG)
        pitch_rate_deg = PITCH_AMPLITUDE_DEG * w * math.cos(w * t)
        # MAVLink angles are in radians.
        self.send(
            self.mav.attitude_send,
            self.time_boot_ms(),
            math.radians(random.gauss(0, 0.1)),  # roll: held level by the rig
            math.radians(pitch_deg),
            0.0,  # yaw
            0.0,
            math.radians(pitch_rate_deg),
            0.0,
        )

    def send_servo_output_raw(self):
        time_usec = int(self.now() * 1e6) & 0xFFFFFFFF
        self.send(self.mav.servo_output_raw_send, time_usec, 0, *self.pwm)

    def send_system_time(self):
        unix_us = 0
        if self.unix_offset_us is not None:
            unix_us = int(self.now() * 1e6) + self.unix_offset_us
        self.send(self.mav.system_time_send, unix_us, self.time_boot_ms())

    def send_named_value_float(self):
        # Stands in for a Lua script calling gcs:send_named_float("DEMO", x).
        value = 1.65 + 0.5 * math.sin(2 * math.pi * self.now() / 10)
        self.send(self.mav.named_value_float_send, self.time_boot_ms(), b"DEMO", value)

    def send_autopilot_version(self):
        caps = (
            mavlink.MAV_PROTOCOL_CAPABILITY_MAVLINK2
            | mavlink.MAV_PROTOCOL_CAPABILITY_PARAM_FLOAT
            | mavlink.MAV_PROTOCOL_CAPABILITY_COMMAND_INT
        )
        sw_version = (FW_MAJOR << 24) | (FW_MINOR << 16) | (FW_PATCH << 8) | FW_TYPE_OFFICIAL
        git_hash = list(b"fakecube")  # 8 bytes, where a real Cube puts its git hash
        self.send(
            self.mav.autopilot_version_send,
            caps,
            sw_version,
            0,  # middleware_sw_version
            0,  # os_sw_version
            0,  # board_version: GUESS, a real Cube's value isn't known yet
            git_hash,
            [0] * 8,
            [0] * 8,
            0,  # vendor_id
            0,  # product_id
            0x00FA6E0C0BE00001,  # uid: made up, recognisably fake
        )

    def send_radio_status(self):
        # Sent by the Wi-Fi bridge, not the autopilot, so it uses the bridge's
        # component ID. The signal numbers are made up.
        self.mav.srcComponent = BRIDGE_COMPONENT
        try:
            self.send(self.mav.radio_status_send, 200, 0, 100, 0, 0, 0, 0)
        finally:
            self.mav.srcComponent = mavlink.MAV_COMP_ID_AUTOPILOT1

    def send_sys_status(self):
        present = enabled = health = SENSOR_MOTOR_OUTPUTS
        if self.safety_on:
            enabled = 0
        self.send(self.mav.sys_status_send, present, enabled, health,
                  100, 12000, -1, -1, 0, 0, 0, 0, 0, 0)

    PERIODIC = {
        "HEARTBEAT": send_heartbeat,
        "ATTITUDE": send_attitude,
        "SERVO_OUTPUT_RAW": send_servo_output_raw,
        "SYSTEM_TIME": send_system_time,
        "NAMED_VALUE_FLOAT": send_named_value_float,
        "RADIO_STATUS": send_radio_status,
        "SYS_STATUS": send_sys_status,
    }

    def send_due_messages(self):
        t = self.now()
        for name, rate in self.rates_hz.items():
            if rate <= 0 or t < self.next_send[name]:
                continue
            self.PERIODIC[name](self)
            self.sent_counts[name] += 1
            # Schedule from the previous due time so the rate doesn't drift,
            # but don't try to catch up if we've fallen far behind.
            self.next_send[name] = max(self.next_send[name] + 1.0 / rate, t)

    # ---- parameters ----------------------------------------------------------

    def send_param(self, name):
        value, ptype = self.params[name]
        self.send(
            self.mav.param_value_send,
            name.encode(),
            float(value),
            ptype,
            len(self.param_names),
            self.param_names.index(name),
        )

    def handle_param_request_list(self, msg):
        self.log(f"PARAM_REQUEST_LIST: sending all {len(self.param_names)} parameters")
        for name in self.param_names:
            self.send_param(name)

    def handle_param_request_read(self, msg):
        name = msg.param_id
        if msg.param_index >= 0:
            if msg.param_index < len(self.param_names):
                name = self.param_names[msg.param_index]
            else:
                name = None
        if name in self.params:
            self.log(f"PARAM_REQUEST_READ {name} = {self.params[name][0]:g}")
            self.send_param(name)
        else:
            self.log(Colour.yellow(f"PARAM_REQUEST_READ for unknown parameter {msg.param_id!r} "
                                   f"(index {msg.param_index}): no reply, like a real Cube"))

    def handle_param_set(self, msg):
        name = msg.param_id
        if name not in self.params:
            self.log(Colour.yellow(f"PARAM_SET for unknown parameter {name!r}: ignored"))
            return
        old, ptype = self.params[name]
        new = msg.param_value
        if ptype != mavlink.MAV_PARAM_TYPE_REAL32:
            new = int(round(new))
        self.params[name] = (new, ptype)
        self.log(Colour.green(f"PARAM_SET {name}: {old:g} -> {new:g}"))
        # A real Cube confirms a write by sending the new value back.
        self.send_param(name)

    # ---- commands ------------------------------------------------------------

    def ack(self, msg, result):
        self.send(self.mav.command_ack_send, msg.command, result, 0, 0,
                  msg.get_srcSystem(), msg.get_srcComponent())

    def handle_command_long(self, msg):
        cmd = msg.command
        handler = {
            mavlink.MAV_CMD_DO_SET_SERVO: self.cmd_set_servo,
            mavlink.MAV_CMD_SET_MESSAGE_INTERVAL: self.cmd_set_message_interval,
            mavlink.MAV_CMD_REQUEST_MESSAGE: self.cmd_request_message,
            mavlink.MAV_CMD_REQUEST_AUTOPILOT_CAPABILITIES: self.cmd_request_capabilities,
            mavlink.MAV_CMD_COMPONENT_ARM_DISARM: self.cmd_arm_disarm,
            CMD_SET_SAFETY_SWITCH_STATE: self.cmd_set_safety,
        }.get(cmd)
        if handler is None:
            name = mavlink.enums["MAV_CMD"].get(cmd)
            name = name.name if name else str(cmd)
            self.log(Colour.yellow(f"COMMAND_LONG {name}: not supported by fake_cube, "
                                   f"replying UNSUPPORTED"))
            self.ack(msg, mavlink.MAV_RESULT_UNSUPPORTED)
            return
        self.ack(msg, handler(msg))

    def cmd_set_servo(self, msg):
        servo = int(round(msg.param1))
        pwm = int(round(msg.param2))
        if not 1 <= servo <= NUM_OUTPUTS:
            self.log(Colour.red(f"DO_SET_SERVO servo {servo}: no such output, FAILED"))
            return mavlink.MAV_RESULT_FAILED
        function = self.params[f"SERVO{servo}_FUNCTION"][0]
        if function not in FREE_FUNCTIONS:
            self.log(Colour.red(f"DO_SET_SERVO servo {servo} -> {pwm}: SERVO{servo}_FUNCTION is "
                                f"{function}, so the output is in use. FAILED"))
            return mavlink.MAV_RESULT_FAILED
        note = ""
        if self.safety_on:
            # A real Cube accepts the command but holds the PWM back from the
            # servo until the safety switch is off. GUESS: SERVO_OUTPUT_RAW
            # still reports the new value.
            note = Colour.yellow("  (safety switch is on: a real servo wouldn't move yet)")
        if not 800 <= pwm <= 2200:
            # A real Cube doesn't refuse this, so neither do we, but it's
            # outside anything a servo expects and CubeGUI should never send it.
            note += Colour.red("  <-- outside 800-2200, CubeGUI's clamp should prevent this")
        self.pwm[servo - 1] = pwm
        self.log(f"DO_SET_SERVO servo {servo} -> {Colour.green(str(pwm))} us{note}")
        return mavlink.MAV_RESULT_ACCEPTED

    def cmd_set_message_interval(self, msg):
        msg_id = int(msg.param1)
        interval_us = msg.param2
        name = MSG_NAMES.get(msg_id)
        if name not in self.rates_hz:
            self.log(Colour.yellow(f"SET_MESSAGE_INTERVAL for message {msg_id}: "
                                   f"fake_cube doesn't stream it, DENIED"))
            return mavlink.MAV_RESULT_DENIED
        if interval_us == -1:
            rate = 0.0
        elif interval_us == 0:
            rate = DEFAULT_RATES_HZ[name]
        else:
            rate = 1e6 / interval_us
        self.rates_hz[name] = rate
        self.next_send[name] = self.now()
        self.log(f"SET_MESSAGE_INTERVAL {name} -> {rate:g} Hz")
        return mavlink.MAV_RESULT_ACCEPTED

    def cmd_request_message(self, msg):
        msg_id = int(msg.param1)
        name = MSG_NAMES.get(msg_id)
        self.log(f"REQUEST_MESSAGE {name or msg_id}")
        if name == "AUTOPILOT_VERSION":
            self.send_autopilot_version()
        elif name in self.PERIODIC:
            self.PERIODIC[name](self)
        else:
            return mavlink.MAV_RESULT_DENIED
        return mavlink.MAV_RESULT_ACCEPTED

    def cmd_request_capabilities(self, msg):
        # The older way of asking for AUTOPILOT_VERSION. Mission Planner uses it.
        self.log("REQUEST_AUTOPILOT_CAPABILITIES")
        self.send_autopilot_version()
        return mavlink.MAV_RESULT_ACCEPTED

    def cmd_set_safety(self, msg):
        # param1: 0 = safe (safety on), 1 = dangerous (safety off, PWM flows).
        if self.old_firmware:
            self.log(Colour.yellow("SET_SAFETY_SWITCH_STATE: --old-firmware, so UNSUPPORTED"))
            return mavlink.MAV_RESULT_UNSUPPORTED
        self.safety_on = int(msg.param1) == 0
        state = "ON (servos held)" if self.safety_on else "OFF (servos live)"
        self.log(Colour.yellow(f"SET_SAFETY_SWITCH_STATE: safety switch {state}"))
        return mavlink.MAV_RESULT_ACCEPTED

    def cmd_arm_disarm(self, msg):
        arm = msg.param1 == 1
        force = int(msg.param2) == 21196  # ArduPilot's magic number for force arm/disarm
        what = ("FORCE " if force else "") + ("ARM" if arm else "DISARM")
        self.log(Colour.red(f"*** {what} REQUEST RECEIVED ***  CubeGUI must never arm without "
                            f"the user confirming."))
        self.armed = arm
        return mavlink.MAV_RESULT_ACCEPTED

    # ---- receiving -----------------------------------------------------------

    def handle_heartbeat(self, msg):
        self.last_gcs_heartbeat = self.now()
        if not self.gcs_seen:
            self.gcs_seen = True
            self.log(Colour.green(f"Ground station heard (system {msg.get_srcSystem()}, "
                                  f"component {msg.get_srcComponent()})"))

    def handle_set_mode(self, msg):
        # The older way to set the safety switch: base_mode exactly 128, and
        # custom_mode 1 for on, 0 for off. Anything else would be a real mode
        # change, which fake_cube doesn't do.
        if msg.base_mode == MODE_FLAG_DECODE_POSITION_SAFETY and msg.custom_mode in (0, 1):
            self.safety_on = msg.custom_mode == 1
            state = "ON (servos held)" if self.safety_on else "OFF (servos live)"
            self.log(Colour.yellow(f"SET_MODE (safety): safety switch {state}"))
        else:
            self.log(Colour.red(f"SET_MODE base_mode {msg.base_mode} custom_mode {msg.custom_mode}: "
                                f"a real mode change! CubeGUI shouldn't send this."))

    def handle_system_time(self, msg):
        if msg.time_unix_usec and self.unix_offset_us is None:
            self.unix_offset_us = msg.time_unix_usec - int(self.now() * 1e6)
            self.log("SYSTEM_TIME from ground station: Cube clock now set to UTC")

    def handle(self, msg):
        kind = msg.get_type()
        if kind == "BAD_DATA":
            if self.verbose:
                self.log(Colour.yellow("received bytes that weren't valid MAVLink"))
            return
        if self.verbose and kind != "HEARTBEAT":
            self.log(Colour.dim(f"<- {msg}"))
        handler = {
            "HEARTBEAT": self.handle_heartbeat,
            "SYSTEM_TIME": self.handle_system_time,
            "SET_MODE": self.handle_set_mode,
            "COMMAND_LONG": self.handle_command_long,
            "PARAM_REQUEST_LIST": self.handle_param_request_list,
            "PARAM_REQUEST_READ": self.handle_param_request_read,
            "PARAM_SET": self.handle_param_set,
        }.get(kind)
        if handler:
            handler(msg)
        elif not self.verbose:
            self.log(Colour.dim(f"received {kind} (ignored)"))

    # ---- main loop -----------------------------------------------------------

    def print_summary(self):
        t = self.now()
        if t < self.next_summary:
            return
        self.next_summary += 5.0
        sent = ", ".join(f"{name} {count / 5:.0f}/s"
                         for name, count in self.sent_counts.items() if count)
        self.sent_counts = {name: 0 for name in self.rates_hz}
        if self.last_gcs_heartbeat is None:
            gcs = Colour.yellow("no ground station heartbeat yet")
        elif t - self.last_gcs_heartbeat > 3:
            gcs = Colour.yellow(f"ground station silent for {t - self.last_gcs_heartbeat:.0f} s")
        else:
            gcs = Colour.green("ground station OK")
        self.log(Colour.dim(f"sending {sent} | ") + gcs)

    def run(self):
        self.log(f"fake_cube sending to {self.target}, listening on UDP port "
                 f"{self.listen_port}. Press Ctrl+C to stop.")
        self.send(self.mav.statustext_send, mavlink.MAV_SEVERITY_INFO,
                  f"ArduPlane V{FW_MAJOR}.{FW_MINOR}.{FW_PATCH} (fake_cube)".encode())
        while True:
            # Handle everything that has arrived, then send what's due.
            while True:
                msg = self.conn.recv_match(blocking=False)
                if msg is None:
                    break
                self.handle(msg)
            self.send_due_messages()
            self.print_summary()
            time.sleep(0.002)


def main():
    parser = argparse.ArgumentParser(description="A pretend Cube Orange+ for testing CubeGUI.")
    parser.add_argument("--target", default="127.0.0.1:14550",
                        help="ground station address and UDP port (default 127.0.0.1:14550)")
    parser.add_argument("--listen-port", type=int, default=14555,
                        help="UDP port to send from and listen on, like the Kahuna's (default 14555)")
    parser.add_argument("--sysid", type=int, default=1, help="MAVLink system ID (default 1)")
    parser.add_argument("--verbose", action="store_true",
                        help="print every message received from the ground station")
    parser.add_argument("--fresh", action="store_true",
                        help="start like a freshly flashed Cube, before the guide's parameter changes")
    parser.add_argument("--old-firmware", action="store_true",
                        help="refuse MAV_CMD_DO_SET_SAFETY_SWITCH_STATE, like ArduPlane before 4.6")
    parser.add_argument("--uptime", type=float, default=0.0,
                        help="pretend the Cube booted this many seconds ago (default 0)")
    parser.add_argument("--no-colour", action="store_true", help="plain text output")
    args = parser.parse_args()

    Colour.on = not args.no_colour and sys.stdout.isatty()
    cube = FakeCube(args.target, args.listen_port, args.sysid, args.verbose, args.fresh,
                    args.old_firmware, args.uptime)
    try:
        cube.run()
    except KeyboardInterrupt:
        print("\nfake_cube stopped.")


if __name__ == "__main__":
    main()
