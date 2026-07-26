#!/usr/bin/env python3
"""Check the CH32 demo FAILURE marker through a Pico/SimpleGlitcher.

Run this while ``glitch_sweep_ch32_gpio.py`` is stopped:

    python3 examples/check_ch32_failure_pin.py --port /dev/ttyACM0

The demo wiring is CH32 PC4 (PIN_FAIL) -> glitcher G15/GP15.  The target
normally pulses this signal high on every failed authentication attempt.
"""

import argparse
import ast

from findus import PicoGlitcher


def parse_args() -> argparse.Namespace:
    parser = argparse.ArgumentParser(
        description="Poll GP15 and verify that the CH32 failure marker toggles.",
        formatter_class=argparse.ArgumentDefaultsHelpFormatter,
    )
    parser.add_argument("--port", default="/dev/ttyACM0", help="Pico/SimpleGlitcher serial port")
    parser.add_argument("--pin", type=int, default=15, help="Pico GPIO connected to CH32 PC4")
    parser.add_argument("--duration-ms", type=int, default=1000, help="Observation time")
    parser.add_argument("--pull", choices=("down", "up", "none"), default="down")
    return parser.parse_args()


def micropython_probe(pin: int, duration_ms: int, pull: str) -> str:
    pull_arg = {
        "down": "machine.Pin.PULL_DOWN",
        "up": "machine.Pin.PULL_UP",
        "none": "None",
    }[pull]
    return f"""
import machine, time
_check_pin = machine.Pin({pin}, machine.Pin.IN, {pull_arg})
_start_ms = time.ticks_ms()
_deadline = time.ticks_add(_start_ms, {duration_ms})
_last = _check_pin.value()
_initial = _last
_last_change_us = time.ticks_us()
_transitions = 0
_rises = 0
_falls = 0
_high_reads = 0
_low_reads = 0
_high_min_us = None
_high_max_us = None
_low_min_us = None
_low_max_us = None
while time.ticks_diff(_deadline, time.ticks_ms()) > 0:
    _value = _check_pin.value()
    if _value:
        _high_reads += 1
    else:
        _low_reads += 1
    if _value != _last:
        _now_us = time.ticks_us()
        _state_us = time.ticks_diff(_now_us, _last_change_us)
        # The first interval may have begun before polling, so omit its width.
        if _transitions:
            if _last:
                _high_min_us = _state_us if _high_min_us is None else min(_high_min_us, _state_us)
                _high_max_us = _state_us if _high_max_us is None else max(_high_max_us, _state_us)
            else:
                _low_min_us = _state_us if _low_min_us is None else min(_low_min_us, _state_us)
                _low_max_us = _state_us if _low_max_us is None else max(_low_max_us, _state_us)
        _transitions += 1
        if _value:
            _rises += 1
        else:
            _falls += 1
        _last = _value
        _last_change_us = _now_us
print((_initial, _last, _transitions, _rises, _falls,
       _high_reads, _low_reads, _high_min_us, _high_max_us,
       _low_min_us, _low_max_us))
"""


def format_range(minimum: int | None, maximum: int | None) -> str:
    if minimum is None:
        return "not measured"
    return f"{minimum}..{maximum} us"


def main() -> int:
    args = parse_args()
    if args.duration_ms <= 0:
        raise SystemExit("--duration-ms must be greater than zero")
    if not 0 <= args.pin <= 29:
        raise SystemExit("--pin must be a valid RP2040 GPIO number (0..29)")

    glitcher = PicoGlitcher()
    try:
        glitcher.init(port=args.port)
        pyboard = glitcher.pico_glitcher.pyb
        stdout, stderr = pyboard.exec_raw(
            micropython_probe(args.pin, args.duration_ms, args.pull),
            timeout=max(10, args.duration_ms / 1000 + 2),
        )
        if stderr:
            print(stderr.decode("utf-8", errors="replace"))
            return 2
        result = ast.literal_eval(stdout.decode("utf-8").strip())
    finally:
        if glitcher.pico_glitcher is not None:
            try:
                glitcher.pico_glitcher.pyb.close()
            except Exception:
                pass

    (
        initial,
        final,
        transitions,
        rises,
        falls,
        high_reads,
        low_reads,
        high_min_us,
        high_max_us,
        low_min_us,
        low_max_us,
    ) = result

    print(f"GP{args.pin}: initial={initial}, final={final}")
    print(f"Edges: {transitions} total ({rises} rising, {falls} falling)")
    print(f"Poll observations: high={high_reads}, low={low_reads}")
    print(f"Completed high widths: {format_range(high_min_us, high_max_us)}")
    print(f"Completed low widths:  {format_range(low_min_us, low_max_us)}")

    if rises and falls and high_reads and low_reads:
        print("PASS: FAILURE is toggling high and low.")
        return 0
    if high_reads and not low_reads:
        print("FAIL: FAILURE stayed high; check for a short to VCC or wrong firmware.")
    elif low_reads and not high_reads:
        print("FAIL: FAILURE stayed low; check CH32 PC4 -> G15 and common ground.")
    else:
        print("INCONCLUSIVE: only one edge was seen; retry with a longer duration.")
    return 1


if __name__ == "__main__":
    raise SystemExit(main())
