#!/usr/bin/env python3
import sys
from pathlib import Path

import pikepdf


def eprint(*args, **kwargs):
    print(*args, file=sys.stderr, **kwargs)


def usage():
    eprint("Usage: set-trim-boxes.py <input-pdf> <output-pdf> <trim-margin-mm>")


def mm_to_pt(mm: float) -> float:
    return mm * 72.0 / 25.4


def main():
    if len(sys.argv) != 4:
        usage()
        sys.exit(2)

    input_pdf = Path(sys.argv[1])
    output_pdf = Path(sys.argv[2])
    trim_margin_mm = float(sys.argv[3])
    inset = mm_to_pt(trim_margin_mm)

    if not input_pdf.is_file():
        eprint(f"ERROR: input file not found: {input_pdf}")
        sys.exit(1)
    if trim_margin_mm < 0:
        eprint("ERROR: trim margin must be >= 0")
        sys.exit(1)

    with pikepdf.open(input_pdf) as pdf:
        for idx, page in enumerate(pdf.pages, start=1):
            media = [float(x) for x in page.MediaBox]
            if len(media) != 4:
                eprint(f"ERROR: invalid MediaBox on page {idx}")
                sys.exit(1)
            x0, y0, x1, y1 = media
            w = x1 - x0
            h = y1 - y0
            if w <= 2 * inset or h <= 2 * inset:
                eprint(
                    f"ERROR: page {idx} too small for trim margin {trim_margin_mm:.2f} mm "
                    f"(size {w:.2f} x {h:.2f} pt)"
                )
                sys.exit(1)

            trim = [x0 + inset, y0 + inset, x1 - inset, y1 - inset]
            page.TrimBox = pikepdf.Array(trim)
            page.BleedBox = pikepdf.Array([x0, y0, x1, y1])
            page.CropBox = pikepdf.Array([x0, y0, x1, y1])

        pdf.save(output_pdf, min_version="1.6")

    print(f"Wrote {output_pdf}")


if __name__ == "__main__":
    main()
