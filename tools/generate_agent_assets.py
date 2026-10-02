#!/usr/bin/env python3
from __future__ import annotations

import argparse
import json
from pathlib import Path

from PIL import Image, ImageDraw

import send_divoom_image


CANVAS = 32
DISPLAY_SIZE = 128
FRAME_MS = 125
PALETTE = {
    "background": "#07111f",
    "shell": "#d7e3f4",
    "shadow": "#667792",
    "face": "#111b32",
    "cyan": "#32e6e2",
    "purple": "#9567ff",
    "yellow": "#ffd447",
    "orange": "#ff8a3d",
    "green": "#5ee884",
    "white": "#f7fbff",
}


def rect(draw: ImageDraw.ImageDraw, box: tuple[int, int, int, int], color: str) -> None:
    draw.rectangle(box, fill=PALETTE[color])


def pixel_pilot(frame: int, state: str) -> Image.Image:
    image = Image.new("RGB", (CANVAS, CANVAS), PALETTE["background"])
    draw = ImageDraw.Draw(image)

    bob = -1 if state == "completed" and frame in (2, 3) else 0
    rect(draw, (8, 9 + bob, 23, 23 + bob), "shadow")
    rect(draw, (7, 8 + bob, 22, 22 + bob), "shell")
    rect(draw, (9, 11 + bob, 20, 18 + bob), "face")
    rect(draw, (11, 7 + bob, 18, 8 + bob), "shell")
    antenna_color = "purple" if frame % 4 < 2 else "cyan"
    rect(draw, (14, 4 + bob, 15, 7 + bob), "shadow")
    rect(draw, (14, 3 + bob, 15, 4 + bob), antenna_color)
    rect(draw, (5, 12 + bob, 7, 17 + bob), "shell")
    rect(draw, (22, 12 + bob, 24, 17 + bob), "shell")
    rect(draw, (10, 22 + bob, 13, 25 + bob), "shadow")
    rect(draw, (17, 22 + bob, 20, 25 + bob), "shadow")

    if state == "idle":
        eye_y = 15 if frame % 8 in (6, 7) else 14
        rect(draw, (11, eye_y + bob, 13, eye_y + bob), "purple")
        rect(draw, (16, eye_y + bob, 18, eye_y + bob), "purple")
        star_x = 2 + frame * 3
        rect(draw, (star_x % 29, 4, star_x % 29 + 1, 5), "cyan")
    elif state == "working":
        scan_x = 11 + (frame % 4) * 2
        rect(draw, (scan_x, 13 + bob, scan_x + 1, 15 + bob), "cyan")
        rect(draw, (18 - (frame % 4) * 2, 13 + bob, 19 - (frame % 4) * 2, 15 + bob), "cyan")
        rect(draw, (8, 25, 22, 27), "purple")
        rect(draw, (10 + frame % 6, 24, 12 + frame % 6, 24), "cyan")
        rect(draw, (25 + frame % 3, 8 - frame % 3, 26 + frame % 3, 9 - frame % 3), "cyan")
    elif state == "asking-input":
        rect(draw, (11, 13 + bob, 12, 15 + bob), "yellow")
        rect(draw, (17, 13 + bob, 18, 15 + bob), "yellow")
        hand_y = 9 if frame % 4 < 2 else 8
        rect(draw, (23, hand_y, 25, 14), "shell")
        if frame % 2 == 0:
            rect(draw, (25, 4, 28, 5), "yellow")
            rect(draw, (28, 5, 29, 8), "yellow")
            rect(draw, (27, 8, 28, 9), "yellow")
            rect(draw, (27, 11, 28, 12), "orange")
    elif state == "completed":
        rect(draw, (11, 13 + bob, 12, 15 + bob), "green")
        rect(draw, (17, 13 + bob, 18, 15 + bob), "green")
        rect(draw, (24, 8, 25, 11), "green")
        rect(draw, (25, 10, 26, 12), "green")
        rect(draw, (26, 9, 29, 10), "green")
        confetti = [(3, 5, "yellow"), (27, 18, "purple"), (4, 22, "cyan"), (24, 3, "green")]
        for index, (x, y, color) in enumerate(confetti):
            yy = (y + frame * 2 + index) % 28
            rect(draw, (x, yy, x + 1, yy + 1), color)
    else:
        raise ValueError(f"unsupported state: {state}")

    return image.resize((DISPLAY_SIZE, DISPLAY_SIZE), Image.Resampling.NEAREST)


def write_status(status: str, output_dir: Path) -> dict[str, int | str]:
    frames = [pixel_pilot(index, status) for index in range(8)]
    raw_frames = [frame.tobytes("raw", "RGB") for frame in frames]
    payload = send_divoom_image._animation_payload(
        raw_frames,
        size=DISPLAY_SIZE,
        speed=FRAME_MS,
        level=17,
        window_log=17,
    )
    packets = send_divoom_image.build_packets(payload)

    preview_path = output_dir / f"{status}-preview.gif"
    frames[0].save(
        preview_path,
        save_all=True,
        append_images=frames[1:],
        duration=FRAME_MS,
        loop=0,
        optimize=False,
    )
    packet_path = output_dir / f"{status}-packets-lenpref.bin"
    packet_data = bytearray()
    for packet in packets:
        packet_data += len(packet).to_bytes(2, "little") + packet
    packet_path.write_bytes(packet_data)
    return {
        "status": status,
        "frames": len(frames),
        "frame_ms": FRAME_MS,
        "payload_bytes": len(payload),
        "packet_count": len(packets),
        "packet_bytes": sum(map(len, packets)),
        "preview": preview_path.name,
        "packets": packet_path.name,
    }


def main() -> int:
    parser = argparse.ArgumentParser(description="Generate Pixel Pilot status animations and Divoom packets")
    parser.add_argument(
        "--output-dir",
        type=Path,
        default=Path(__file__).resolve().parent.parent / "agent-assets",
    )
    args = parser.parse_args()
    args.output_dir.mkdir(parents=True, exist_ok=True)
    manifest = [write_status(status, args.output_dir) for status in ("idle", "working", "asking-input", "completed")]
    (args.output_dir / "manifest.json").write_text(json.dumps(manifest, indent=2) + "\n", encoding="utf-8")
    print(json.dumps(manifest, indent=2))
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
