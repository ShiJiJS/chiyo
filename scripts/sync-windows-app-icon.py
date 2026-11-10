"""Wrap the existing approved PNG icon sizes in ICO, without redrawing them."""
from pathlib import Path
import struct

root = Path(__file__).resolve().parent.parent
source = root / "apps/desktop/macos/Runner/Assets.xcassets/AppIcon.appiconset"
frames = []
for size in (16, 32, 64, 128, 256):
    data = (source / f"app_icon_{size}.png").read_bytes()
    if data[:8] != b"\x89PNG\r\n\x1a\n" or struct.unpack(">II", data[16:24]) != (size, size):
        raise ValueError("Invalid original icon frame")
    frames.append((size, data))
offset = 6 + 16 * len(frames)
entries = []
for size, data in frames:
    entries.append(struct.pack("<BBBBHHII", size % 256, size % 256, 0, 0, 1, 32, len(data), offset))
    offset += len(data)
destination = root / "apps/desktop/windows/runner/resources/app_icon.ico"
destination.write_bytes(
    struct.pack("<HHH", 0, 1, len(frames))
    + b"".join(entries)
    + b"".join(data for _, data in frames)
)
print("Synchronized five unchanged original PNG frames into the Windows icon.")
