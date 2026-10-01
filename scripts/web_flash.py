#!/usr/bin/env python3
"""Build OpenHaldex-S3 images and serve the local browser installer."""

from __future__ import annotations

import argparse
from functools import partial
from http.server import SimpleHTTPRequestHandler, ThreadingHTTPServer
import json
from pathlib import Path
import shutil
import sys
import webbrowser

from flash import DEFAULT_ENVIRONMENT, FLASH_LAYOUT, FlashError, build_images, find_platformio, load_version


PROJECT_DIR = Path(__file__).resolve().parents[1]
INSTALLER_DIR = PROJECT_DIR / "tools" / "web-installer"
BUILD_DIR = INSTALLER_DIR / "build"


class InstallerRequestHandler(SimpleHTTPRequestHandler):
    """Serve installer files without caching stale firmware images."""

    def end_headers(self) -> None:
        self.send_header("Cache-Control", "no-store")
        self.send_header("Access-Control-Allow-Origin", "*")
        super().end_headers()


def prepare_build(environment: str, skip_build: bool) -> None:
    if not skip_build:
        pio = find_platformio()
        build_images(pio, environment, filesystem_only=False, dry_run=False)

    source_dir = PROJECT_DIR / ".pio" / "build" / environment
    image_names = ("bootloader.bin", "partitions.bin", "firmware.bin", "littlefs.bin")
    missing = [name for name in image_names if not (source_dir / name).is_file()]
    if missing:
        raise FlashError(
            "Missing build output: "
            + ", ".join(str(source_dir / name) for name in missing)
            + ". Run again without --skip-build."
        )

    BUILD_DIR.mkdir(parents=True, exist_ok=True)
    for name in image_names:
        shutil.copy2(source_dir / name, BUILD_DIR / name)

    (BUILD_DIR / "otadata-initial.bin").write_bytes(b"\xff" * 0x2000)
    manifest = {
        "name": "OpenHaldex S3 (local build)",
        "version": load_version(),
        "new_install_prompt_erase": True,
        "new_install_improv_wait_time": 0,
        "builds": [
            {
                "chipFamily": "ESP32-S3",
                "parts": [
                    {"path": "bootloader.bin", "offset": FLASH_LAYOUT["bootloader"]},
                    {"path": "partitions.bin", "offset": FLASH_LAYOUT["partitions"]},
                    {"path": "otadata-initial.bin", "offset": FLASH_LAYOUT["otadata"]},
                    {"path": "firmware.bin", "offset": FLASH_LAYOUT["firmware"]},
                    {"path": "littlefs.bin", "offset": FLASH_LAYOUT["littlefs"]},
                ],
            }
        ],
    }
    (BUILD_DIR / "manifest.json").write_text(
        json.dumps(manifest, indent=2) + "\n", encoding="utf-8"
    )


def parse_args() -> argparse.Namespace:
    parser = argparse.ArgumentParser(
        description="Build OpenHaldex-S3 and flash it through a local browser installer."
    )
    parser.add_argument("--environment", default=DEFAULT_ENVIRONMENT, help=argparse.SUPPRESS)
    parser.add_argument("--skip-build", action="store_true", help="use existing build output")
    parser.add_argument("--host", default="127.0.0.1", help=argparse.SUPPRESS)
    parser.add_argument("--port", default=8765, type=int, help="local web-server port (default: 8765)")
    parser.add_argument("--no-open", action="store_true", help="do not open the browser automatically")
    return parser.parse_args()


def main() -> int:
    args = parse_args()
    print("Preparing the OpenHaldex browser installer...")
    prepare_build(args.environment, args.skip_build)

    handler = partial(InstallerRequestHandler, directory=str(INSTALLER_DIR))
    try:
        server = ThreadingHTTPServer((args.host, args.port), handler)
    except OSError as exc:
        raise FlashError(
            f"Could not start the local installer on port {args.port}. "
            "Close the program using that port or choose another with --port."
        ) from exc
    url = f"http://localhost:{args.port}/"
    print(f"\nInstaller ready: {url}")
    print("Keep this window open until flashing finishes. Press Ctrl-C afterward.")
    if not args.no_open:
        webbrowser.open(url)

    try:
        server.serve_forever()
    except KeyboardInterrupt:
        print("\nInstaller stopped.")
    finally:
        server.server_close()
    return 0


if __name__ == "__main__":
    try:
        raise SystemExit(main())
    except FlashError as exc:
        print(f"\nError: {exc}", file=sys.stderr)
        raise SystemExit(2)
