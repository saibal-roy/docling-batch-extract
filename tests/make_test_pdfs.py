"""Generate the PDFs used by the acceptance tests.

Usage: make_test_pdfs.py <outdir>

Creates text PDFs of 3, 5, 15 and 60 pages (headings, paragraphs, a table per page),
a 20-page simulated scan (each page is one full-page image, no text layer) and a
corrupt bad.pdf.
"""
import sys
from pathlib import Path

from PIL import Image, ImageDraw, ImageFont
from reportlab.lib import colors
from reportlab.lib.pagesizes import A4
from reportlab.lib.styles import getSampleStyleSheet
from reportlab.pdfgen import canvas
from reportlab.platypus import PageBreak, Paragraph, SimpleDocTemplate, Table, TableStyle

TEXT_PDFS = {"small_a": 3, "small_b": 5, "medium": 15, "large": 60}
SCANNED_PAGES = 20


def sentence(page, k):
    return (f"Paragraph {k + 1} on page {page}. The quarterly revenue for region {page % 7} grew by "
            f"{(page * 3 + k) % 17} percent compared with the previous period, driven by new customers.")


def text_pdf(path, pages):
    ss = getSampleStyleSheet()
    story = []
    for p in range(1, pages + 1):
        story.append(Paragraph(f"Section {p}: {path.stem} page {p}", ss["Heading1"]))
        story += [Paragraph(sentence(p, k), ss["BodyText"]) for k in range(3)]
        t = Table([["Item", "Qty", "Price"]] + [[f"P{p}-{i}", str(i * p), f"{i * 9.5:.2f}"] for i in range(1, 5)])
        t.setStyle(TableStyle([("GRID", (0, 0), (-1, -1), 0.5, colors.black)]))
        story += [t, PageBreak()]
    SimpleDocTemplate(str(path), pagesize=A4).build(story)


def scanned_pdf(path, pages):
    """Each page is a 150 dpi bitmap of rendered text, like a scanner produces."""
    w, h = A4
    px = (int(w / 72 * 150), int(h / 72 * 150))
    font = ImageFont.load_default(size=28)
    c = canvas.Canvas(str(path), pagesize=A4)
    for p in range(1, pages + 1):
        img = Image.new("L", px, 255)
        d = ImageDraw.Draw(img)
        d.text((120, 120), f"Scanned page {p}: sample document", font=ImageFont.load_default(size=40))
        y = 240
        for k in range(12):
            words = sentence(p, k).split()
            for line in (" ".join(words[:9]), " ".join(words[9:])):
                d.text((120, y), line, font=font)
                y += 44
            y += 30
        tmp = path.with_suffix(f".p{p}.png")
        img.save(tmp)
        c.drawImage(str(tmp), 0, 0, width=w, height=h)
        c.showPage()
        tmp.unlink()
    c.save()


def main():
    out = Path(sys.argv[1])
    out.mkdir(parents=True, exist_ok=True)
    for name, pages in TEXT_PDFS.items():
        text_pdf(out / f"{name}.pdf", pages)
    scanned_pdf(out / "scanned.pdf", SCANNED_PAGES)
    (out / "bad.pdf").write_bytes(b"%PDF-1.4\nthis is not a real pdf\n")
    print(f"test PDFs written to {out}")


if __name__ == "__main__":
    main()
