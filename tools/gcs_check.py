#!/usr/bin/env python3
"""A quick check that a Cube (real or fake) answers the way CubeGUI expects.

It does, in Python, roughly what CubeGUI's comms will do in MATLAB:

 1. listen on a UDP port for the Cube's heartbeat
 2. ask for ATTITUDE and SERVO_OUTPUT_RAW at 20 Hz
 3. ask for AUTOPILOT_VERSION
 4. read a parameter
 5. move one servo with DO_SET_SERVO and check the output follows

Each step prints PASS or FAIL. Use it to check fake_cube.py, or (carefully,
with nothing attached that can be damaged) a real Cube.

Usage:
    python tools/gcs_check.py                 # listen on UDP port 14550
    python tools/gcs_check.py --servo 5 --pwm 1600

Close Mission Planner first: only one program can listen on the port.
"""

import argparse
import os
import sys
import time

os.environ.setdefault("MAVLINK20", "1")

from pymavlink import mavutil  # noqa: E402

mavlink = mavutil.mavlink

failures = 0


def report(ok, text):
    global failures
    print(("PASS  " if ok else "FAIL  ") + text, flush=True)
    if not ok:
        failures += 1


def wait_for(conn, kind, timeout, condition=lambda m: True):
    """Wait up to `timeout` seconds for a message of type `kind` matching `condition`."""
    end = time.monotonic() + timeout
    while time.monotonic() < end:
        msg = conn.recv_match(type=kind, blocking=True, timeout=0.1)
        if msg is not None and condition(msg):
            return msg
    return None


def command(conn, cmd, *params):
    """Send a COMMAND_LONG and wait for its COMMAND_ACK. Returns the result code."""
    params = list(params) + [0] * (7 - len(params))
    conn.mav.command_long_send(conn.target_system, conn.target_component, cmd, 0, *params)
    ack = wait_for(conn, "COMMAND_ACK", 2.0, lambda m: m.command == cmd)
    return None if ack is None else ack.result


def measure_rate(conn, kind, seconds):
    count = 0
    end = time.monotonic() + seconds
    while time.monotonic() < end:
        if conn.recv_match(type=kind, blocking=True, timeout=0.1) is not None:
            count += 1
    return count / seconds


def main():
    parser = argparse.ArgumentParser(description="Check a Cube answers the way CubeGUI expects.")
    parser.add_argument("--port", type=int, default=14550, help="UDP port to listen on (default 14550)")
    parser.add_argument("--servo", type=int, default=5, help="output to move (default 5)")
    parser.add_argument("--pwm", type=int, default=1600, help="PWM to send, in microseconds (default 1600)")
    args = parser.parse_args()

    if not 1000 <= args.pwm <= 2000:
        sys.exit("--pwm must be between 1000 and 2000")

    try:
        conn = mavutil.mavlink_connection(f"udpin:0.0.0.0:{args.port}",
                                          source_system=255, source_component=190,
                                          dialect="ardupilotmega")
    except OSError as err:
        sys.exit(f"Couldn't listen on UDP port {args.port} ({err}). Is Mission Planner open?")

    # 1. Heartbeat. wait_heartbeat also records which system to talk to.
    print(f"Listening on UDP port {args.port} for a heartbeat...")
    hb = conn.wait_heartbeat(timeout=10)
    report(hb is not None, "heartbeat received" if hb else "no heartbeat within 10 s")
    if hb is None:
        sys.exit(1)
    # Talk to the autopilot component that sent the heartbeat.
    conn.target_component = hb.get_srcComponent()
    print(f"      system {conn.target_system}, component {conn.target_component}, "
          f"autopilot type {hb.autopilot}, vehicle type {hb.type}")
    # Send our own heartbeat so the Cube knows a ground station is there.
    conn.mav.heartbeat_send(mavlink.MAV_TYPE_GCS, mavlink.MAV_AUTOPILOT_INVALID, 0, 0, 0)

    # 2. Message rates.
    for name in ("ATTITUDE", "SERVO_OUTPUT_RAW"):
        msg_id = getattr(mavlink, f"MAVLINK_MSG_ID_{name}")
        result = command(conn, mavlink.MAV_CMD_SET_MESSAGE_INTERVAL, msg_id, 1e6 / 20)
        report(result == mavlink.MAV_RESULT_ACCEPTED, f"{name} at 20 Hz requested (result {result})")
    rate = measure_rate(conn, "ATTITUDE", 2.0)
    report(rate >= 15, f"ATTITUDE arriving at {rate:.1f} Hz")
    att = wait_for(conn, "ATTITUDE", 1.0)
    if att:
        print(f"      pitch {att.pitch * 57.29578:+.1f} deg at time_boot_ms {att.time_boot_ms}")

    # 3. Version. The reply can arrive before or after the COMMAND_ACK, so
    # wait for both together: waiting for the ACK alone would throw the
    # version message away if it came first.
    conn.mav.command_long_send(conn.target_system, conn.target_component,
                               mavlink.MAV_CMD_REQUEST_MESSAGE, 0,
                               mavlink.MAVLINK_MSG_ID_AUTOPILOT_VERSION, 0, 0, 0, 0, 0, 0)
    ver = None
    end = time.monotonic() + 3.0
    while ver is None and time.monotonic() < end:
        msg = conn.recv_match(type=["AUTOPILOT_VERSION", "COMMAND_ACK"], blocking=True, timeout=0.1)
        if msg is not None and msg.get_type() == "AUTOPILOT_VERSION":
            ver = msg
    report(ver is not None, "AUTOPILOT_VERSION received")
    if ver:
        v = ver.flight_sw_version
        print(f"      firmware {v >> 24}.{(v >> 16) & 0xFF}.{(v >> 8) & 0xFF}, "
              f"board_version {ver.board_version}, uid {ver.uid:#x}")

    # 4. A parameter.
    pname = f"SERVO{args.servo}_FUNCTION"
    conn.mav.param_request_read_send(conn.target_system, conn.target_component, pname.encode(), -1)
    pv = wait_for(conn, "PARAM_VALUE", 2.0, lambda m: m.param_id == pname)
    report(pv is not None, f"{pname} read" + (f": {pv.param_value:g}" if pv else ""))

    # 5. Move a servo and check SERVO_OUTPUT_RAW follows.
    result = command(conn, mavlink.MAV_CMD_DO_SET_SERVO, args.servo, args.pwm)
    report(result == mavlink.MAV_RESULT_ACCEPTED, f"DO_SET_SERVO {args.servo} -> {args.pwm} (result {result})")
    field = f"servo{args.servo}_raw"
    out = wait_for(conn, "SERVO_OUTPUT_RAW", 2.0, lambda m: getattr(m, field) == args.pwm)
    report(out is not None, f"SERVO_OUTPUT_RAW shows output {args.servo} at {args.pwm}")

    print()
    print("All checks passed." if failures == 0 else f"{failures} check(s) failed.")
    sys.exit(1 if failures else 0)


if __name__ == "__main__":
    main()
