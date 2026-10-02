#!/usr/bin/env python3
from __future__ import annotations

import argparse
import json
import socket
import time
from pathlib import Path


STATUSES = ("idle", "working", "asking-input", "completed")


def submit(host: str, port: int, packets_path: Path, delay: float, dry_run: bool) -> dict:
    request = {
        "packets": str(packets_path.resolve()),
        "delay": delay,
        "dryRun": dry_run,
    }
    deadline = time.monotonic() + 5
    while True:
        try:
            connection = socket.create_connection((host, port), timeout=10)
            break
        except OSError as error:
            if time.monotonic() >= deadline:
                raise RuntimeError(f"could not connect to Divoom daemon at {host}:{port}") from error
            time.sleep(0.2)
    with connection:
        connection.sendall(json.dumps(request).encode() + b"\n")
        connection.shutdown(socket.SHUT_WR)
        response = bytearray()
        while True:
            chunk = connection.recv(4096)
            if not chunk:
                break
            response.extend(chunk)
    if not response.strip():
        raise RuntimeError("empty daemon response")
    return json.loads(response)


def main() -> int:
    parser = argparse.ArgumentParser(description="Display a prebuilt agent status animation on Divoom MiniToo")
    parser.add_argument("status", choices=STATUSES)
    parser.add_argument("--asset-dir", type=Path, required=True)
    parser.add_argument("--host", default="127.0.0.1")
    parser.add_argument("--port", type=int, default=40583)
    parser.add_argument("--delay", type=float, default=0.012)
    parser.add_argument("--daemon-dry-run", action="store_true")
    args = parser.parse_args()

    packet_path = args.asset_dir / f"{args.status}-packets-lenpref.bin"
    if not packet_path.is_file():
        parser.error(f"status packet file not found: {packet_path}")

    response = submit(args.host, args.port, packet_path, args.delay, args.daemon_dry_run)
    print(json.dumps(response, ensure_ascii=False))
    return 0 if response.get("ok") else 2


if __name__ == "__main__":
    raise SystemExit(main())
