"""Deterministic fictional files and PDF page previews for the isolated UI.

Requires bundled reportlab, Pillow and Poppler. No personal files or network.
The app uses this known-fixture adapter, not an arbitrary-PDF renderer; a real
owner adapter must render its own managed content through the same contract.
"""
from pathlib import Path
import hashlib
import json
import subprocess

from PIL import Image, ImageDraw
from reportlab.pdfgen.canvas import Canvas
from reportlab.lib.pagesizes import A4
from pypdf import PdfReader

ROOT = Path(__file__).resolve().parents[2]
OUTPUT = ROOT / "apps/desktop/assets/zhiyu_files"


def digest(path):
    return hashlib.sha256(path.read_bytes()).hexdigest()


def generate():
    OUTPUT.mkdir(parents=True, exist_ok=True)
    entries = []
    for version in (1, 2):
        path = OUTPUT / f"resume-v{version}.pdf"
        canvas = Canvas(str(path), pagesize=A4, invariant=1, pageCompression=1)
        canvas.setTitle(f"Fictional Resume - Lin Yuan - v{version}")
        canvas.setAuthor("Zhiyu fictional UI fixtures")
        for page in range(version):
            canvas.setFillColorRGB(.15, .17, .21)
            canvas.setFont("Helvetica-Bold", 24)
            canvas.drawString(54, 776, "LIN YUAN" if page == 0 else "PROJECT NOTES")
            canvas.setFont("Helvetica", 11)
            lines = [
                "Backend engineering | Fictional record for interface development",
                "yuan.lin@example.com | Shanghai",
                "",
                "EDUCATION",
                "Beichen University - Computer Technology, 2024-2027",
                "",
                "EXPERIENCE",
                "Backend intern, April-August 2026",
                "Worked on task scheduling, service monitoring and recovery.",
                "",
                "PROJECT",
                "Task management tool" if version == 1 else "Information and credential authorization workspace",
                "Designed structured owner-managed information and access workflows.",
                "",
                "SKILLS",
                "Go / Java / SQL / Linux / Docker",
            ] if page == 0 else [
                "ADDITIONAL PROJECT DETAILS",
                "This is the second page of an actual bundled PDF.",
                "The file-preview UI must display the selected immutable version.",
                "Replacing or restoring this file creates a new current version.",
                "No personal data, account credential or executable content is included.",
            ]
            for i, line in enumerate(lines):
                canvas.drawString(54, 735 - i * 22, line)
            canvas.setFont("Helvetica", 9)
            canvas.drawString(54, 42, f"Fictional fixture | version {version} | page {page+1}/{version}")
            canvas.showPage()
        canvas.save()
        reader = PdfReader(path)
        assert len(reader.pages) == version
        assert "LIN YUAN" in reader.pages[0].extract_text()
        prefix = OUTPUT / f"resume-v{version}-page"
        subprocess.run(["pdftoppm", "-r", "96", "-png", str(path), str(prefix)], check=True)
        pages = sorted(OUTPUT.glob(prefix.name + "-*.png"))
        assert len(pages) == version
        entries.append({
            "id": f"pdf-v{version}", "asset": path.name,
            "filename": f"Lin-Yuan-Resume-v{version}.pdf", "mediaType": "application/pdf",
            "byteLength": path.stat().st_size, "sha256": digest(path),
            "pages": [{"asset": p.name, "sha256": digest(p), "text": reader.pages[i].extract_text()} for i, p in enumerate(pages)],
        })
    image = Image.new("RGB", (480, 480), "#e8eef8")
    draw = ImageDraw.Draw(image)
    draw.ellipse((100, 100, 380, 380), fill="#66528e")
    draw.rectangle((195, 175, 285, 305), fill="white")
    image_path = OUTPUT / "geometric.png"
    image.save(image_path)
    text_path = OUTPUT / "maintenance.txt"
    text_path.write_text("Maintenance checklist\n1. Verify host identity.\n2. Check approved access scope.\n3. Record the result.\n", encoding="utf-8")
    unknown_path = OUTPUT / "unsupported.bin"
    unknown_path.write_bytes(b"ZHIYU-UNSUPPORTED-FICTIONAL-FILE\x00\x01\x02")
    for id_, path, media in [("image", image_path, "image/png"), ("text", text_path, "text/plain"), ("unknown", unknown_path, "application/octet-stream")]:
        entries.append({"id": id_, "asset": path.name, "filename": path.name,
                        "mediaType": media, "byteLength": path.stat().st_size,
                        "sha256": digest(path), "pages": []})
    (OUTPUT / "manifest.json").write_text(json.dumps({"generator": str(Path(__file__).relative_to(ROOT)), "files": entries}, ensure_ascii=False, indent=2) + "\n", encoding="utf-8")
    print(f"Generated 2 fictional PDFs, 3 rendered PDF pages and 3 other files in {OUTPUT}")


if __name__ == "__main__":
    generate()
