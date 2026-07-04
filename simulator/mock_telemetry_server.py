#!/usr/bin/env python3
"""Laptop telemetry simulator for the Dominar 400 TFT dashboard prototype.

Run:
    python3 simulator/mock_telemetry_server.py

Then open:
    http://127.0.0.1:8765

No external Python packages are required.
"""

from __future__ import annotations

import json
import math
import time
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer
from pathlib import Path
from typing import Any, Dict
from urllib.parse import urlsplit

ROOT = Path(__file__).resolve().parents[1]
DASHBOARD = ROOT / "dashboard" / "index.html"
MANIFEST = ROOT / "dashboard" / "manifest.webmanifest"
ICON = ROOT / "dashboard" / "icon.svg"
HOST = "0.0.0.0"
PORT = 8765
HZ = 40.0
RPM_SWEEP_SECONDS = 20.0
TEMP_STEP_SECONDS = 10.0
SERVER_START = time.monotonic()


def clamp(value: float, low: float, high: float) -> float:
    return max(low, min(high, value))


def triangle_sweep(t: float, period: float) -> float:
    phase = (t % period) / period
    linear = phase * 2 if phase < 0.5 else (1 - phase) * 2
    edge_boost = 0.1
    return clamp(linear + edge_boost * math.sin(2 * math.pi * linear) / (2 * math.pi), 0, 1)


def shared_tick() -> tuple[int, float]:
    elapsed = time.monotonic() - SERVER_START
    seq = int(elapsed * HZ)
    return seq, seq / HZ


def deterministic_jitter(seq: int, salt: int, low: float, high: float) -> float:
    raw = math.sin(seq * 12.9898 + salt * 78.233) * 43758.5453
    frac = raw - math.floor(raw)
    return low + (high - low) * frac


def fake_telemetry(seq: int, t: float) -> Dict[str, Any]:
    """Generate smooth motorcycle-like telemetry for UI testing."""
    sweep = triangle_sweep(t, RPM_SWEEP_SECONDS)
    temp_phase = int(t // TEMP_STEP_SECONDS) % 2
    throttle = sweep * 100
    rpm = sweep * 10000
    speed = sweep * 100
    coolant = 70 if temp_phase == 0 else 80
    iat = 31 + 2.2 * math.sin(t * 0.12)
    manifold = clamp(29 + throttle * 0.58 + 5 * math.sin(t * 1.6), 20, 104)
    vbatt = 14.12 + 0.08 * math.sin(t * 0.9)
    fuel = clamp(82 - t * 0.018, 8, 100)
    lam = clamp(0.98 + 0.06 * math.sin(t * 2.1), 0.82, 1.12)

    if speed < 3:
        gear = "N"
    elif speed < 23:
        gear = "1"
    elif speed < 43:
        gear = "2"
    elif speed < 68:
        gear = "3"
    elif speed < 94:
        gear = "4"
    elif speed < 125:
        gear = "5"
    else:
        gear = "6"

    def jitter(low: float, high: float, salt: int) -> float:
        return deterministic_jitter(seq, salt, low, high)

    payload = {
        "seq": seq,
        "ts_ms": int(t * 1000),
        "source": "simulator",
        "rpm": round(rpm, 1),
        "speed_kph": round(speed, 1),
        "speed": round(speed, 1),
        "gear": gear,
        "fuel_pct": round(fuel, 1),
        "ambient_c": round(32 + 1.5 * math.sin(t * 0.05), 1),
        "coolant_c": round(coolant + jitter(-0.15, 0.15, 1), 1),
        "coolant": round(coolant + jitter(-0.15, 0.15, 2), 1),
        "engine_temp_c": round(coolant, 1),
        "iat_c": round(iat + jitter(-0.1, 0.1, 3), 1),
        "iat": round(iat + jitter(-0.1, 0.1, 4), 1),
        "map_kpa": round(manifold + jitter(-0.8, 0.8, 5), 1),
        "map": round(manifold + jitter(-0.8, 0.8, 6), 1),
        "tps_pct": round(throttle + jitter(-0.5, 0.5, 7), 1),
        "tps": round(throttle + jitter(-0.5, 0.5, 8), 1),
        "battery_v": round(vbatt, 2),
        "vbatt": round(vbatt, 2),
        "lambda": round(lam, 2),
        "afr": round(lam * 14.7, 1),
        "ignition_deg": round(6 + throttle * 0.18 + 4 * math.sin(t * 1.1), 1),
        "injector_ms": round(1.7 + throttle * 0.075 + 0.4 * math.sin(t * 1.7), 2),
        "engine_load_pct": round(clamp(throttle * 0.95 + 8 * math.sin(t * 1.3), 0, 100), 1),
        "fuel_rate_lph": round(clamp(0.6 + rpm / 1700 + throttle / 32, 0.4, 9.5), 2),
        "fuel_used_l": round(t * 0.00021, 3),
        "range_km": round(fuel * 3.2, 0),
        "oil_temp_c": round(coolant + 8 + 2 * math.sin(t * 0.07), 1),
        "oil_pressure_status": 1 if rpm > 1000 else 0,
        "fan_on": coolant > 92,
        "mil_on": False,
        "dtc_count": 0,
        "side_stand_down": False,
        "abs_active": False,
        "can_bitrate": 500000,
        "link_quality_pct": 100,
        "packet_rate_hz": HZ,
    }
    return payload


class Handler(BaseHTTPRequestHandler):
    server_version = "DominarTFTSim/0.2"

    def send_file(self, path: Path, content_type: str) -> None:
        self.send_response(200)
        self.send_header("Content-Type", content_type)
        self.send_header("Cache-Control", "no-store, no-cache, must-revalidate, max-age=0")
        self.send_header("Pragma", "no-cache")
        self.send_header("Expires", "0")
        self.end_headers()
        self.wfile.write(path.read_bytes())

    def do_GET(self) -> None:
        path = urlsplit(self.path).path

        if path in ("/", "/index.html"):
            self.send_file(DASHBOARD, "text/html; charset=utf-8")
            return

        if path == "/manifest.webmanifest":
            self.send_file(MANIFEST, "application/manifest+json; charset=utf-8")
            return

        if path in ("/icon.svg", "/apple-touch-icon.svg"):
            self.send_file(ICON, "image/svg+xml; charset=utf-8")
            return

        if path == "/events":
            self.send_response(200)
            self.send_header("Content-Type", "text/event-stream")
            self.send_header("Cache-Control", "no-cache")
            self.send_header("Connection", "keep-alive")
            self.send_header("Access-Control-Allow-Origin", "*")
            self.end_headers()

            last_seq = -1
            try:
                while True:
                    seq, t = shared_tick()
                    if seq != last_seq:
                        payload = fake_telemetry(seq, t)
                        message = f"data: {json.dumps(payload, separators=(',', ':'))}\n\n"
                        self.wfile.write(message.encode("utf-8"))
                        self.wfile.flush()
                        last_seq = seq

                    next_tick_at = SERVER_START + ((last_seq + 1) / HZ)
                    time.sleep(max(0.001, next_tick_at - time.monotonic()))
            except (BrokenPipeError, ConnectionResetError):
                return

        self.send_error(404, "Not found")

    def log_message(self, fmt: str, *args: object) -> None:
        if self.path != "/events":
            super().log_message(fmt, *args)


def main() -> None:
    server = ThreadingHTTPServer((HOST, PORT), Handler)
    print(f"Dominar TFT telemetry dashboard on this Mac: http://127.0.0.1:{PORT}")
    print(f"On iPhone, open: http://<your-mac-wifi-ip>:{PORT}")
    print(f"Streaming mock telemetry at {HZ:.0f} Hz. Press Ctrl+C to stop.")
    try:
        server.serve_forever()
    except KeyboardInterrupt:
        print("\nStopping.")
    finally:
        server.server_close()


if __name__ == "__main__":
    main()
