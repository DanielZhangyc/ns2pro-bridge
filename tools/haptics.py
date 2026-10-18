#!/usr/bin/env python3
"""Send leased dual-band haptics to an explicitly connected NS2 Pro Bridge."""
import argparse
import json
import math
import os
import socket
import time


def band(values):
    low_amplitude, low_frequency, high_amplitude, high_frequency = values
    if not all(math.isfinite(value) for value in values):
        raise ValueError("All amplitudes and frequencies must be finite")
    if not 0 <= low_amplitude <= 1 or not 0 <= high_amplitude <= 1:
        raise ValueError("Amplitudes must be between 0 and 1")
    if not 40 <= low_frequency <= 1252 or not 40 <= high_frequency <= 1252:
        raise ValueError("Frequencies must be between 40 and 1252 Hz")
    return dict(lowAmplitude=low_amplitude, lowFrequency=low_frequency,
                highAmplitude=high_amplitude, highFrequency=high_frequency)


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--socket", default=os.path.expanduser("~/.ns2pro-bridge/haptics.sock"))
    parser.add_argument("--left", nargs=4, type=float, default=[0, 160, 0, 320],
                        metavar=("LOW_AMP", "LOW_HZ", "HIGH_AMP", "HIGH_HZ"))
    parser.add_argument("--right", nargs=4, type=float, default=[0, 160, 0, 320],
                        metavar=("LOW_AMP", "LOW_HZ", "HIGH_AMP", "HIGH_HZ"))
    parser.add_argument("--seconds", type=float, default=0.5)
    args = parser.parse_args()
    if not math.isfinite(args.seconds) or not 0 <= args.seconds <= 60:
        parser.error("--seconds must be between 0 and 60")
    try:
        frame = dict(version=1, durationMilliseconds=200, left=band(args.left), right=band(args.right))
    except ValueError as error:
        parser.error(str(error))
    with socket.socket(socket.AF_UNIX, socket.SOCK_DGRAM) as client:
        client.connect(args.socket)
        deadline = time.monotonic() + args.seconds
        try:
            while time.monotonic() < deadline:
                client.send(json.dumps(frame, allow_nan=False).encode())
                time.sleep(min(0.05, max(0, deadline - time.monotonic())))
        finally:
            frame["durationMilliseconds"] = 0
            client.send(json.dumps(frame, allow_nan=False).encode())


if __name__ == "__main__":
    main()
