#!/usr/bin/env python3
"""读取真实本机 DSU 数据并检查 CRC，不生成样本。
Read actual loopback DSU data and verify CRCs without generating samples.
"""
import argparse
import json
import math
import socket
import statistics
import struct
import time
import zlib
from pathlib import Path


def request(kind, payload=b""):
    packet = bytearray(struct.pack("<4sHHIII", b"DSUC", 1001, 4 + len(payload), 0, 1, kind) + payload)
    struct.pack_into("<I", packet, 8, zlib.crc32(packet))
    return packet


def decode(packet):
    if len(packet) < 20:
        raise ValueError("DSU response is shorter than its header")
    magic, version, length, crc, server, kind = struct.unpack_from("<4sHHIII", packet)
    if magic != b"DSUS" or version != 1001 or length + 16 != len(packet):
        raise ValueError("Invalid DSU response header")
    checked = bytearray(packet)
    checked[8:12] = bytes(4)
    if zlib.crc32(checked) != crc:
        raise ValueError("DSU response CRC mismatch")
    return server, kind


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--port", type=int, default=26760)
    parser.add_argument("--seconds", type=float, default=10)
    parser.add_argument("--output", type=Path, help="Optional JSONL path for actual received packets")
    args = parser.parse_args()
    if not math.isfinite(args.seconds) or args.seconds <= 0 or not 1 <= args.port <= 65535:
        parser.error("seconds must be finite and positive; port must be 1..65535")
    samples = []
    inactive = 0
    previous = None
    server_id = None
    info = None
    version = None
    start = time.monotonic()
    renew = start
    output = args.output.open("x", encoding="utf-8") if args.output else None
    try:
        with socket.socket(socket.AF_INET, socket.SOCK_DGRAM) as client:
            client.connect(("127.0.0.1", args.port))
            client.settimeout(0.2)
            client.send(request(0x100000))
            client.send(request(0x100001, struct.pack("<IB", 1, 0)))
            while time.monotonic() - start < args.seconds:
                if time.monotonic() >= renew:
                    client.send(request(0x100002, bytes(8)))
                    renew = time.monotonic() + 1
                try:
                    packet = client.recv(1024)
                except TimeoutError:
                    continue
                server, kind = decode(packet)
                if server_id is not None and server != server_id:
                    raise ValueError("DSU server changed during the capture")
                server_id = server
                if kind == 0x100000:
                    if len(packet) != 22:
                        raise ValueError("Invalid DSU version response length")
                    version = struct.unpack_from("<H", packet, 20)[0]
                elif kind == 0x100001:
                    if len(packet) != 32:
                        raise ValueError("Invalid DSU controller response length")
                    info = {"slot": packet[20], "state": packet[21], "model": packet[22], "connection": packet[23]}
                elif kind == 0x100002:
                    if len(packet) != 100:
                        raise ValueError("Invalid DSU motion response length")
                    if not packet[31]:
                        inactive += 1
                        previous = None
                        break
                    timestamp, *values = struct.unpack_from("<Q6f", packet, 68)
                    if previous is not None and timestamp <= previous:
                        raise ValueError("DSU motion timestamps did not increase")
                    if not all(math.isfinite(value) for value in values):
                        raise ValueError("Non-finite DSU motion value")
                    previous = timestamp
                    row = {"host_received": time.monotonic(), "timestamp_us": timestamp,
                           "acceleration_g": values[:3], "gyro_dps": values[3:], "packet_hex": packet.hex()}
                    samples.append(row)
                    if output:
                        output.write(json.dumps(row) + "\n")
    finally:
        if output:
            output.close()
    result = {"protocol_version": version, "controller": info, "samples": len(samples), "inactive_packets": inactive}
    if samples:
        elapsed = (samples[-1]["timestamp_us"] - samples[0]["timestamp_us"]) / 1e6
        result["sample_span_seconds"] = elapsed
        result["received_hz"] = (len(samples) - 1) / elapsed if elapsed > 0 else None
        for field in ("acceleration_g", "gyro_dps"):
            axes = list(zip(*(row[field] for row in samples)))
            result[field] = {"mean": [statistics.mean(axis) for axis in axes],
                             "min": [min(axis) for axis in axes], "max": [max(axis) for axis in axes]}
        result["mean_acceleration_norm_g"] = statistics.mean(
            math.sqrt(sum(value * value for value in row["acceleration_g"])) for row in samples)
    print(json.dumps(result, indent=2))
    if not samples:
        raise SystemExit("No active motion samples received")


if __name__ == "__main__":
    main()
