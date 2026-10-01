#!/usr/bin/env python3
"""Generate deterministic gzip copies of the large WebUI assets."""

from __future__ import annotations

import gzip
from pathlib import Path


ASSETS = ("app.js", "styles.css")


def generate(project_dir: Path) -> None:
    data_dir = project_dir / "data"
    for name in ASSETS:
        source = data_dir / name
        destination = data_dir / f"{name}.gz"
        if not source.is_file():
            raise RuntimeError(f"Missing WebUI asset: {source}")

        original = source.read_bytes()
        compressed = gzip.compress(original, compresslevel=9, mtime=0)
        if destination.is_file() and destination.read_bytes() == compressed:
            continue

        destination.write_bytes(compressed)
        reduction = 100.0 * (1.0 - (len(compressed) / len(original)))
        print(
            f"gzip_web_assets: {name} {len(original)} -> {len(compressed)} bytes "
            f"({reduction:.1f}% smaller)"
        )


if "Import" in globals():
    Import("env")
    generate(Path(env["PROJECT_DIR"]))
elif __name__ == "__main__":
    generate(Path(__file__).resolve().parents[1])
