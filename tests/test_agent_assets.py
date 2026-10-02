from __future__ import annotations

import json
import socketserver
import sys
import tempfile
import threading
import unittest
from pathlib import Path


ROOT = Path(__file__).resolve().parents[1]
sys.path.insert(0, str(ROOT / "tools"))

import divoom_status
import divoom_clock
import send_divoom_image


class RequestHandler(socketserver.BaseRequestHandler):
    request_body = b""

    def handle(self) -> None:
        chunks = []
        while True:
            chunk = self.request.recv(4096)
            if not chunk:
                break
            chunks.append(chunk)
        type(self).request_body = b"".join(chunks)
        self.request.sendall(b'{"ok":true,"message":"dry run","packets":3,"bytes":12}\n')


class AgentAssetTests(unittest.TestCase):
    def test_generated_packet_files_are_valid(self) -> None:
        manifest = json.loads((ROOT / "agent-assets" / "manifest.json").read_text())
        self.assertEqual(
            {entry["status"] for entry in manifest},
            {"idle", "working", "asking-input", "completed"},
        )
        for entry in manifest:
            data = (ROOT / "agent-assets" / entry["packets"]).read_bytes()
            offset = 0
            packets = []
            while offset < len(data):
                length = int.from_bytes(data[offset : offset + 2], "little")
                offset += 2
                packets.append(data[offset : offset + length])
                offset += length
            self.assertEqual(offset, len(data))
            self.assertEqual(len(packets), entry["packet_count"])
            self.assertTrue(all(packet[0] == 0x01 and packet[-1] == 0x02 for packet in packets))

    def test_status_client_submits_absolute_packet_path(self) -> None:
        with tempfile.TemporaryDirectory() as temp_dir:
            packet_path = Path(temp_dir) / "idle-packets-lenpref.bin"
            packet_path.write_bytes(b"\x01\x00x")
            with socketserver.TCPServer(("127.0.0.1", 0), RequestHandler) as server:
                thread = threading.Thread(target=server.handle_request)
                thread.start()
                response = divoom_status.submit(
                    "127.0.0.1",
                    server.server_address[1],
                    packet_path,
                    0.012,
                    True,
                )
                thread.join(timeout=2)
            self.assertTrue(response["ok"])
            request = json.loads(RequestHandler.request_body)
            self.assertEqual(request["packets"], str(packet_path.resolve()))
            self.assertTrue(request["dryRun"])

    def test_clock_client_does_not_require_animation_ack(self) -> None:
        with tempfile.TemporaryDirectory() as temp_dir:
            packet_path = Path(temp_dir) / "clock-packets-lenpref.bin"
            packet_path.write_bytes(b"\x01\x00x")
            with socketserver.TCPServer(("127.0.0.1", 0), RequestHandler) as server:
                thread = threading.Thread(target=server.handle_request)
                thread.start()
                response = divoom_clock.submit(
                    "127.0.0.1",
                    server.server_address[1],
                    packet_path,
                )
                thread.join(timeout=2)
            self.assertTrue(response["ok"])
            request = json.loads(RequestHandler.request_body)
            self.assertFalse(request["requireAck"])

    def test_win00_clock_packet_uses_builtin_id(self) -> None:
        packet = divoom_clock.build_select_clock_packet(1084)
        self.assertIn(b'"ClockId":1084', packet)

    def test_status_assets_use_supported_animation_shape(self) -> None:
        frames = [bytes(128 * 128 * 3)] * 2
        payload = send_divoom_image._animation_payload(frames, size=128, speed=125, level=17)
        self.assertEqual(payload[0], 0x25)
        self.assertEqual(payload[1], 2)
        self.assertEqual(payload[2:4], (125).to_bytes(2, "big"))
        self.assertEqual(payload[4:6], bytes([8, 8]))


if __name__ == "__main__":
    unittest.main()
