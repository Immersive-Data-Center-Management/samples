#!/usr/bin/env python3
"""Generates the printable QR code labels for Experiment 2.

One label per component of DemoRack01 (and one of DemoRack02, to show the
"not part of this rack" case). Each QR code holds the component's AAS shell id,
exactly what a real sticker on a server would carry. The app does not ship these
images; they are for printing only.

    pip install "qrcode[pil]==8.2"
    python generate_qr_codes.py

Writes one PNG per label plus all_labels.png (an A4 sheet at 150 dpi) next to this script.
"""

from pathlib import Path

import qrcode
from PIL import Image, ImageDraw, ImageFont

# (label, rack slot, shell id) - must match RACKS in shared/deploy/seed/seed.py
LABELS = [
    ("DemoServer01", "Rack 01 · U 2", "urn:apeirora.eu:aas:demo:server-01"),
    ("DemoServer02", "Rack 01 · U 3", "urn:apeirora.eu:aas:demo:server-02"),
    ("DemoServer03", "Rack 01 · U 4-6", "urn:apeirora.eu:aas:demo:server-03"),
    ("DemoPsu01", "Rack 01 · U 12-14", "urn:apeirora.eu:aas:demo:psu-01"),
    ("DemoPsu02", "Rack 01 · U 15-17", "urn:apeirora.eu:aas:demo:psu-02"),
    ("DemoServer04", "Rack 02 · U 6-8", "urn:apeirora.eu:aas:demo:server-04"),
]

OUT = Path(__file__).parent
LABEL_W, LABEL_H = 600, 760  # px, about 10 x 13 cm at 150 dpi


def font(size):
    for name in ("arial.ttf", "DejaVuSans.ttf", "Helvetica.ttc"):
        try:
            return ImageFont.truetype(name, size)
        except OSError:
            pass
    return ImageFont.load_default()


def make_label(title, slot, shell_id):
    qr = qrcode.QRCode(error_correction=qrcode.constants.ERROR_CORRECT_M, border=2, box_size=12)
    qr.add_data(shell_id)
    qr.make(fit=True)
    code = qr.make_image(fill_color="black", back_color="white").convert("RGB")
    code = code.resize((520, 520), Image.NEAREST)

    label = Image.new("RGB", (LABEL_W, LABEL_H), "white")
    draw = ImageDraw.Draw(label)
    draw.rectangle([4, 4, LABEL_W - 5, LABEL_H - 5], outline="black", width=3)
    label.paste(code, ((LABEL_W - 520) // 2, 30))
    draw.text((LABEL_W // 2, 580), title, fill="black", font=font(48), anchor="mm")
    draw.text((LABEL_W // 2, 640), slot, fill="black", font=font(32), anchor="mm")
    draw.text((LABEL_W // 2, 700), shell_id, fill="#555555", font=font(18), anchor="mm")
    return label


def main():
    labels = []
    for title, slot, shell_id in LABELS:
        img = make_label(title, slot, shell_id)
        img.save(OUT / f"{title}.png", dpi=(150, 150))
        labels.append(img)

    # A4 at 150 dpi (1240 x 1754 px), 2 x 3 labels scaled to fit the cells with a gap.
    sheet = Image.new("RGB", (1240, 1754), "white")
    w, h = 430, 545  # keeps the label aspect ratio (600 x 760)
    for i, img in enumerate(labels):
        col, row = i % 2, i // 2
        sheet.paste(img.resize((w, h), Image.LANCZOS), (130 + col * (w + 120), 30 + row * (h + 30)))
    sheet.save(OUT / "all_labels.png", dpi=(150, 150))
    print(f"wrote {len(labels)} labels and all_labels.png to {OUT}")


if __name__ == "__main__":
    main()
