"""Downloads the two YOLOX models (Apache-2.0) into vision/models and checks
them. Run by the build; also handy for running the program from the sources."""
from __future__ import annotations

import hashlib
import sys
import urllib.request
from pathlib import Path

BASE = "https://github.com/Megvii-BaseDetection/YOLOX/releases/download/0.1.1rc0/"
MODELS = {
    "yolox_s.onnx": "c5c2d13e59ae883e6af3b45daea64af4833a4951c92d116ec270d9ddbe998063",
    "yolox_tiny.onnx": "427cc366d34e27ff7a03e2899b5e3671425c262ea2291f88bb942bc1cc70b0f7",
}


def sha256(path: Path) -> str:
    h = hashlib.sha256()
    with path.open("rb") as f:
        for chunk in iter(lambda: f.read(1 << 20), b""):
            h.update(chunk)
    return h.hexdigest()


def main() -> int:
    target = Path(__file__).resolve().parent.parent / "models"
    target.mkdir(exist_ok=True)
    for name, digest in MODELS.items():
        path = target / name
        if path.exists() and sha256(path) == digest:
            print(f"{name}: ok")
            continue
        print(f"{name}: downloading...")
        urllib.request.urlretrieve(BASE + name, path)
        if sha256(path) != digest:
            path.unlink(missing_ok=True)
            print(f"{name}: checksum mismatch", file=sys.stderr)
            return 1
        print(f"{name}: ok")
    return 0


if __name__ == "__main__":
    sys.exit(main())
