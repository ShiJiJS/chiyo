"""Unscaled QA composites; original HTML and Flutter captures remain untouched."""
from pathlib import Path
from PIL import Image, ImageChops, ImageDraw, ImageEnhance

root = Path(__file__).resolve().parents[3]
evidence = root / "docs/development/evidence/23-workspace/fidelity"
pairs = [(name, f"approvals-{name}") for name in ("purple-1440", "green-1440", "purple-1280")]
pairs += [("purple-1440-scope", "scope-purple-1440"), ("purple-1440-handled", "handled-purple-1440"), ("purple-1440-organization", "organization-pending-purple-1440"), ("purple-1440-organization-complete", "organization-complete-purple-1440")]
for name, reference_name in pairs:
    reference = Image.open(root / f"docs/design/prototype-reference/{reference_name}.png").convert("RGB")
    actual = Image.open(evidence / f"{name}.png").convert("RGB")
    assert reference.size == actual.size
    width, height = actual.size
    board = Image.new("RGB", (width * 2, (height + 24) * 2), "#eeeeee")
    panels = [
        ("HTML reference", reference),
        ("Flutter actual", actual),
        ("50% overlay - QA only", Image.blend(reference, actual, 0.5)),
        ("Difference x3 - QA only, no pass score", ImageEnhance.Brightness(ImageChops.difference(reference, actual)).enhance(3)),
    ]
    draw = ImageDraw.Draw(board)
    for index, (label, panel) in enumerate(panels):
        x = (index % 2) * width
        y = (index // 2) * (height + 24)
        draw.text((x + 8, y + 5), label, fill="black")
        board.paste(panel, (x, y + 24))
    board.save(evidence / f"{name}-comparison.png")
