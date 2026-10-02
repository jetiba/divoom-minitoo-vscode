# Divoom MiniToo macOS Daemon

Tools for sending images, GIFs, and short videos to a **Divoom MiniToo** over Bluetooth Classic RFCOMM from macOS.

The core of this repo is a Swift daemon that keeps the Divoom app channel open, plus a small macOS menu-bar app, a Copilot agent-status dashboard, and Python media conversion tooling.

> `omo-slim/` contains local working media/assets and is not the main project API. The reusable project is the daemon, menu-bar app, CLI, and protocol notes.

## Upstream and attribution

This project is derived from [alvinunreal/divoom-minitoo-osx](https://github.com/alvinunreal/divoom-minitoo-osx) by Alvin Unreal. The original Git history is preserved. This version adds the Pixel Pilot agent-status dashboard, VS Code Accessibility-based state detection, automatic paired-device discovery, precompiled status animations, tests, and reproducible Python packaging.

The upstream repository does not currently declare an open-source license. A GitHub fork preserves the clearest attribution and repository relationship; obtain the upstream author's permission or an explicit license before redistributing this derivative outside the GitHub fork network.

GitHub Copilot and Divoom are trademarks of their respective owners. This project is an independent integration and is not affiliated with or endorsed by GitHub or Divoom.

## What this does

- Opens the Divoom MiniToo app protocol over Bluetooth RFCOMM channel `1`.
- Avoids repeated macOS Bluetooth audio reconnect/disconnect by keeping one daemon connection open.
- Converts PNG/JPEG/GIF/MP4/video into the Divoom animation payload format.
- Sends jobs through a localhost daemon at `127.0.0.1:40583`.
- Provides a copyable macOS `.app` that starts the daemon from the menu bar.
- Displays VS Code Copilot agent states as original Pixel Pilot animations: working, asking for input, completed, and idle.

## Device assumptions

The menu-bar app discovers a paired device whose Bluetooth name contains `Divoom MiniToo`. The protocol defaults remain available for direct CLI use:

```text
Bluetooth name: Divoom MiniToo-Audio
Fallback MAC:   B1:21:81:B1:F0:84
RFCOMM channel: 1
Daemon port:    40583
```

If auto-discovery is unavailable, pass your device address manually to `tools/divoom-daemon`.

## Requirements

- macOS
- Xcode Command Line Tools / Swift compiler
- Bluetooth access for the menu-bar app when macOS prompts for it

For development CLI use:

- Python virtualenv with `Pillow`, `zstandard`, and `pyserial`
- `ffmpeg` for GIF/video input

Create the project Python environment with:

```bash
tools/setup-python-env.sh
```

The packaged app bundles the repo `.venv`, so normal app usage does not need the active shell Python environment.

## Build the macOS app

```bash
tools/build-divoom-app.sh
```

This builds:

```text
build/Divoom MiniToo.app
```

Install it:

```bash
cp -R "build/Divoom MiniToo.app" /Applications/
open "/Applications/Divoom MiniToo.app"
```

On launch, the app:

1. Disconnects the Divoom macOS audio profile using the native IOBluetooth framework.
2. Starts the Swift RFCOMM daemon.
3. Keeps the daemon available from the menu bar.
4. Uses macOS Accessibility, when granted, to detect active Copilot execution and permission/input prompts.
5. Optionally watches Copilot OpenTelemetry as a fallback when the VS Code build exports complete agent traces.

Logs and generated packet artifacts are written under:

```text
~/Library/Application Support/DivoomMiniToo/
```

## Menu-bar app

The menu-bar title indicates daemon state:

```text
◇ Divoom = daemon stopped
◆ Divoom = daemon running
```

Useful actions:

- **Send Image/GIF/Video…** — choose a media file and send it.
- **Disconnect Audio + Start Daemon** — use when macOS audio owns the Bluetooth connection.
- **Restart Daemon** — stop, disconnect audio, and reopen RFCOMM.
- **Copy Copilot OTel Settings** — copy the required privacy-preserving VS Code settings.
- **Enable Accessibility Detection…** — request permission to detect visible confirmation controls.
- **Preview: …** — send any dashboard state to the device without running an agent.
- **Open Menu Log / Open Daemon Log** — inspect failures.

## Copilot agent dashboard

The dashboard primarily uses a local macOS Accessibility check:

```text
Visible Stop/Cancel control    -> working
Visible permission/input card -> asking input
Stop/Cancel control disappears -> completed
Eight seconds later           -> idle
Five minutes idle             -> built-in Win00 clock (ClockId 1084)
```

No prompt or response content is read. The app only observes enabled control roles and labels in the VS Code UI.

To detect permission prompts, choose **Enable Accessibility Detection…**, grant access to **Divoom MiniToo** in **System Settings → Privacy & Security → Accessibility**, and relaunch the app. The app only detects prompt controls; it never approves a permission or submits input.

The **Copy Copilot OTel Settings** action remains available as an optional fallback for VS Code builds that export `copilot_chat.session.start` and `invoke_agent` records correctly. It is not required for the Accessibility-driven dashboard.

When several agents are active, the display priority is:

```text
asking input > working > completed > idle
```

After five uninterrupted minutes in the idle state, the app activates the built-in Win00 clock (`ClockId=1084`) once. New Copilot activity cancels the pending timer and immediately replaces the clock with the appropriate Pixel Pilot animation. Each later return to idle starts a fresh five-minute timer.

The original Pixel Pilot assets are generated by:

```bash
python3 tools/generate_agent_assets.py
```

This creates preview GIFs and precompiled packet files in `agent-assets/`. Precompiled packets keep state changes fast and avoid runtime media conversion.

## CLI usage

Start the daemon manually:

```bash
tools/divoom-daemon <MINITOO_MAC> 1 40583
```

Send media through the daemon:

```bash
.venv/bin/python tools/divoom_send.py path/to/image.png
.venv/bin/python tools/divoom_send.py path/to/animation.gif
.venv/bin/python tools/divoom_send.py path/to/video.mp4
```

Recommended compact video/GIF profile:

```bash
.venv/bin/python tools/divoom_send.py path/to/animation.gif \
  --size 128 \
  --fps 8 \
  --speed 125 \
  --max-frames 24 \
  --posterize-bits 4
```

Build packet files without sending:

```bash
.venv/bin/python tools/divoom_send.py path/to/media.mp4 --build-only
```

Ask the daemon to parse but not send:

```bash
.venv/bin/python tools/divoom_send.py path/to/media.mp4 --daemon-dry-run
```

## Integration API

For most integrations, call `divoom_send.py` as a subprocess. It is the media-level API:

```text
image/GIF/video -> Divoom packets -> daemon -> Bluetooth
```

Example:

```bash
"/Applications/Divoom MiniToo.app/Contents/Resources/.venv/bin/python" \
  "/Applications/Divoom MiniToo.app/Contents/Resources/tools/divoom_send.py" \
  "/absolute/path/to/file.gif" \
  --size 128 --fps 8 --speed 125 --max-frames 24 --posterize-bits 4
```

The daemon itself is packet-level. It listens on:

```text
127.0.0.1:40583
```

It accepts JSON pointing to a prebuilt length-prefixed packet file:

```json
{
  "packets": "/absolute/path/to/file-packets-lenpref.bin",
  "delay": 0.012,
  "dryRun": false
}
```

Python example:

```python
import json
import socket

req = {
    "packets": "/absolute/path/to/file-packets-lenpref.bin",
    "delay": 0.012,
    "dryRun": False,
}

with socket.create_connection(("127.0.0.1", 40583), timeout=10) as s:
    s.sendall(json.dumps(req).encode() + b"\n")
    s.shutdown(socket.SHUT_WR)
    print(s.recv(65536).decode())
```

Typical success response:

```json
{"ok":true,"message":"sent","packets":457,"bytes":122949,"sawRequest":true,"sawAck":true}
```

## Protocol notes

Full reverse-engineering notes are in [`PROTOCOL.md`](PROTOCOL.md).

High-level transport:

```text
01 <declared_len_le16> <cmd> <body...> <checksum_le16> 02
```

Animation/photo command:

```text
0x8b = SPP_APP_NEW_GIF_CMD2020
```

Media payloads are RGB888 frames compressed with Zstandard and wrapped in Divoom `0x8b` start/chunk packets.

Important finding:

```text
zstd window_log=17
```

This matches Android captures and avoids black/glitched output seen with larger zstd windows.

## Repository layout

```text
PROTOCOL.md                  Reverse-engineering and validation notes
tools/DivoomDaemon.swift     Swift RFCOMM daemon
tools/DivoomMenuBar.swift    macOS menu-bar controller
tools/AgentDashboard.swift   Copilot telemetry, state aggregation, and permission detection
tools/divoom_send.py         Preferred media send CLI
tools/divoom_status.py       Sends a precompiled dashboard state
tools/generate_agent_assets.py  Generates Pixel Pilot animations and packets
tools/send_divoom_image.py   Image/GIF/video conversion + packet builder
tools/divoom_clock.py        Custom face selection helper
tools/build-divoom-app.sh    Builds packaged macOS app
agent-assets/                Pixel Pilot previews and precompiled Divoom packets
omo-slim/                    Local test/media assets; not core project API
```

## Troubleshooting

If daemon start fails with an RFCOMM error, disconnect the audio profile once:

```bash
Disconnect the MiniToo audio profile from macOS Bluetooth settings.
```

Then restart the daemon or reopen the app.

If a send reports `sent but final ACK not observed`, the device may still have updated successfully. This is usually an ACK-observation issue, not necessarily a failed transfer.

If video/GIF transfer is too slow, reduce frames before reducing pixels:

```bash
--size 128 --fps 6 --speed 167 --max-frames 18 --posterize-bits 4
```

Keep `--zstd-window-log 17` unless deliberately testing protocol behavior.
