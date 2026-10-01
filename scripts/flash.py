#!/usr/bin/env python3
"""Build and flash OpenHaldex-S3 firmware and web assets in one step."""

from __future__ import annotations

import argparse
import json
import os
from pathlib import Path
import platform
import shlex
import shutil
import subprocess
import sys
import time
from typing import Iterable


PROJECT_DIR = Path(__file__).resolve().parents[1]
DEFAULT_ENVIRONMENT = "lilygo-t2can-s3"
DEFAULT_BAUD = 921600

FLASH_LAYOUT = {
    "bootloader": 0x0000,
    "partitions": 0x8000,
    "nvs": 0x9000,
    "otadata": 0xE000,
    "firmware": 0x10000,
    "littlefs": 0x790000,
}

ESPRESSIF_USB_IDS = ("303A:1001", "303A:0002", "303A:4001")
COMMON_USB_SERIAL_IDS = ("10C4:", "1A86:", "0403:")


class FlashError(RuntimeError):
    """A user-actionable flashing error."""


def command_text(command: Iterable[object]) -> str:
    return shlex.join(str(part) for part in command)


def run(
    command: list[str], *, capture: bool = False, dry_run: bool = False, announce: bool = True
) -> subprocess.CompletedProcess[str]:
    if announce:
        print(f"\n> {command_text(command)}")
    if dry_run:
        return subprocess.CompletedProcess(command, 0, "", "")

    environment = os.environ.copy()
    environment.setdefault("PLATFORMIO_SETTING_ENABLE_TELEMETRY", "No")
    return subprocess.run(
        command,
        cwd=PROJECT_DIR,
        env=environment,
        check=True,
        text=True,
        capture_output=capture,
    )


def find_platformio() -> Path:
    override = os.environ.get("PLATFORMIO_CLI")
    if override:
        candidate = Path(override).expanduser()
        if candidate.is_file():
            return candidate
        raise FlashError(f"PLATFORMIO_CLI does not point to a file: {candidate}")

    for name in ("pio", "platformio"):
        found = shutil.which(name)
        if found:
            return Path(found)

    executable_names = (
        ("pio.exe", "platformio.exe") if platform.system() == "Windows" else ("pio", "platformio")
    )
    executable_dir = (
        Path.home()
        / ".platformio"
        / "penv"
        / ("Scripts" if platform.system() == "Windows" else "bin")
    )
    for executable_name in executable_names:
        candidate = executable_dir / executable_name
        if candidate.is_file():
            return candidate

    raise FlashError("PlatformIO was not found. Install PlatformIO Core or the VS Code PlatformIO extension.")


def platformio_core_dir() -> Path:
    configured = os.environ.get("PLATFORMIO_CORE_DIR")
    return Path(configured).expanduser() if configured else Path.home() / ".platformio"


def find_esptool() -> list[str]:
    package = platformio_core_dir() / "packages" / "tool-esptoolpy"
    scripts = [package / "esptool.py", package / "esptool"]
    esptool_script = next((path for path in scripts if path.exists()), None)
    if esptool_script is None:
        raise FlashError("PlatformIO's esptool package is missing. Run a normal PlatformIO build first.")

    penv = platformio_core_dir() / "penv"
    python_candidates = (
        penv / "Scripts" / "python.exe",
        penv / "bin" / "python3",
        penv / "bin" / "python",
    )
    python_executable = next((path for path in python_candidates if path.is_file()), Path(sys.executable))
    if (package / "esptool").is_dir():
        return [str(python_executable), str(package / "esptool")]
    return [str(python_executable), str(esptool_script)]


def list_serial_devices(pio: Path, *, announce: bool = True) -> list[dict[str, str]]:
    result = run([str(pio), "device", "list", "--json-output"], capture=True, announce=announce)
    try:
        devices = json.loads(result.stdout)
    except json.JSONDecodeError as exc:
        raise FlashError("PlatformIO returned an invalid serial-device list.") from exc
    return [device for device in devices if isinstance(device, dict) and device.get("port")]


def device_score(device: dict[str, str]) -> int:
    port = str(device.get("port", ""))
    details = f"{device.get('description', '')} {device.get('hwid', '')}".upper()
    port_upper = port.upper()

    if "BLUETOOTH" in port_upper or "DEBUG-CONSOLE" in port_upper:
        return -1
    if any(identifier in details for identifier in ESPRESSIF_USB_IDS):
        return 100
    if "ESP32" in details or "ESPRESSIF" in details or "USB JTAG" in details:
        return 90
    if any(identifier in details for identifier in COMMON_USB_SERIAL_IDS):
        return 70
    if port_upper.startswith("COM") or "CU.USB" in port_upper or "TTYACM" in port_upper or "TTYUSB" in port_upper:
        return 40
    return 0


def choose_port(pio: Path, requested: str | None) -> str:
    if requested:
        return requested

    devices = list_serial_devices(pio)
    candidates = [(device_score(device), device) for device in devices]
    candidates = [(score, device) for score, device in candidates if score > 0]
    if not candidates:
        listed = ", ".join(str(device["port"]) for device in devices) or "none"
        raise FlashError(
            "No ESP32 USB serial port was detected. Connect the board and try again, "
            f"or pass --port explicitly. Detected ports: {listed}"
        )

    highest_score = max(score for score, _ in candidates)
    best = [device for score, device in candidates if score == highest_score]
    if len(best) != 1:
        ports = ", ".join(str(device["port"]) for device in best)
        raise FlashError(f"More than one likely board was found ({ports}). Select one with --port.")
    return str(best[0]["port"])


def refresh_port(pio: Path, selected_port: str) -> str:
    """Keep the selected path when present, or follow a uniquely re-enumerated ESP32."""
    devices = list_serial_devices(pio, announce=False)
    if any(str(device["port"]) == selected_port for device in devices):
        return selected_port

    replacement = choose_port(pio, None)
    print(f"USB port changed: {selected_port} -> {replacement}")
    return replacement


def require_files(paths: Iterable[Path]) -> None:
    missing = [str(path.relative_to(PROJECT_DIR)) for path in paths if not path.is_file()]
    if missing:
        raise FlashError("Missing build output: " + ", ".join(missing))


def write_blank_image(path: Path, size: int) -> None:
    path.write_bytes(b"\xff" * size)


def build_images(pio: Path, environment: str, filesystem_only: bool, dry_run: bool) -> None:
    if not filesystem_only:
        run([str(pio), "run", "-e", environment], dry_run=dry_run)
    run([str(pio), "run", "-e", environment, "-t", "buildfs"], dry_run=dry_run)


def load_version() -> str:
    try:
        value = json.loads((PROJECT_DIR / "version.json").read_text(encoding="utf-8"))
        return str(value.get("version", "unknown"))
    except (OSError, json.JSONDecodeError, AttributeError):
        return "unknown"


def wait_for_port(pio: Path, original_port: str, timeout_seconds: float = 12.0) -> str | None:
    deadline = time.monotonic() + timeout_seconds
    while time.monotonic() < deadline:
        try:
            devices = list_serial_devices(pio, announce=False)
        except (FlashError, subprocess.CalledProcessError):
            devices = []
        ports = [str(device["port"]) for device in devices]
        if original_port in ports:
            return original_port

        likely = [device for device in devices if device_score(device) > 0]
        if len(likely) == 1:
            return str(likely[0]["port"])
        time.sleep(0.5)
    return None


def parse_args() -> argparse.Namespace:
    parser = argparse.ArgumentParser(
        description="Build and flash OpenHaldex-S3 firmware and LittleFS in one operation."
    )
    mode = parser.add_mutually_exclusive_group()
    mode.add_argument(
        "--clean",
        action="store_true",
        help="also erase saved settings before installing firmware and WebUI",
    )
    mode.add_argument(
        "--filesystem-only",
        action="store_true",
        help="only rebuild and install the WebUI/LittleFS image",
    )
    parser.add_argument("--port", help="serial port; auto-detected when omitted")
    parser.add_argument("--environment", default=DEFAULT_ENVIRONMENT, help=argparse.SUPPRESS)
    parser.add_argument(
        "--baud",
        type=int,
        default=DEFAULT_BAUD,
        help=f"flash baud rate (default: {DEFAULT_BAUD})",
    )
    parser.add_argument("--skip-build", action="store_true", help="flash existing build output")
    parser.add_argument("--dry-run", action="store_true", help="print commands without building or flashing")
    return parser.parse_args()


def main() -> int:
    args = parse_args()
    pio = find_platformio()

    if args.dry_run and not args.port:
        port = "<auto-detected-port>"
    else:
        port = choose_port(pio, args.port)

    print("OpenHaldex-S3 streamlined flasher")
    mode_name = "filesystem only" if args.filesystem_only else "clean install" if args.clean else "normal update"
    print(f"Mode: {mode_name}")
    print(f"Port: {port}")
    if not args.dry_run:
        print("Note: installing LittleFS replaces custom maps and logs; export anything needed first.")

    if not args.skip_build:
        build_images(pio, args.environment, args.filesystem_only, args.dry_run)

    if not args.dry_run:
        port = refresh_port(pio, port)

    build_dir = PROJECT_DIR / ".pio" / "build" / args.environment
    littlefs = build_dir / "littlefs.bin"
    if args.filesystem_only:
        required = [littlefs]
    else:
        required = [
            build_dir / "bootloader.bin",
            build_dir / "partitions.bin",
            build_dir / "firmware.bin",
            littlefs,
        ]

    if not args.dry_run:
        require_files(required)

    esptool = find_esptool()
    flash_command = esptool + [
        "--chip",
        "esp32s3",
        "--port",
        port,
        "--baud",
        str(args.baud),
        "--before",
        "default-reset",
        "--after",
        "hard-reset",
        "write-flash",
        "-z",
        "--flash-mode",
        "qio",
        "--flash-freq",
        "80m",
        "--flash-size",
        "16MB",
    ]

    if args.filesystem_only:
        flash_command += [hex(FLASH_LAYOUT["littlefs"]), str(littlefs)]
    else:
        otadata = build_dir / "otadata-initial.bin"
        if not args.dry_run:
            write_blank_image(otadata, 0x2000)

        flash_pairs: list[tuple[int, Path]] = [
            (FLASH_LAYOUT["bootloader"], build_dir / "bootloader.bin"),
            (FLASH_LAYOUT["partitions"], build_dir / "partitions.bin"),
        ]
        if args.clean:
            nvs = build_dir / "nvs-initial.bin"
            if not args.dry_run:
                write_blank_image(nvs, 0x5000)
            flash_pairs.append((FLASH_LAYOUT["nvs"], nvs))
        flash_pairs += [
            (FLASH_LAYOUT["otadata"], otadata),
            (FLASH_LAYOUT["firmware"], build_dir / "firmware.bin"),
            (FLASH_LAYOUT["littlefs"], littlefs),
        ]
        for offset, image in flash_pairs:
            flash_command += [hex(offset), str(image)]

    run(flash_command, dry_run=args.dry_run)
    if args.dry_run:
        print("\nDry run complete; nothing was written.")
        return 0

    detected_port = wait_for_port(pio, port)
    print("\nFlash complete and image checks passed.")
    print(f"Firmware: {load_version()}")
    if detected_port:
        print(f"Application serial port: {detected_port}")
    else:
        print("The application serial port did not reappear automatically; press RESET once.")
    print("Wi-Fi: OpenHaldex-S3")
    print("Web UI: http://192.168.4.1 or http://openhaldex.local")
    return 0


if __name__ == "__main__":
    try:
        raise SystemExit(main())
    except FlashError as exc:
        print(f"\nError: {exc}", file=sys.stderr)
        raise SystemExit(2)
    except subprocess.CalledProcessError as exc:
        if exc.stderr:
            print(exc.stderr.strip(), file=sys.stderr)
        print(f"\nCommand failed with exit code {exc.returncode}.", file=sys.stderr)
        raise SystemExit(exc.returncode)
