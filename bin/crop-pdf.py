#!/usr/bin/env python3
import sys
from pathlib import Path

import pikepdf


POINTS_PER_MM = 72.0 / 25.4


def eprint(*args, **kwargs):
    print(*args, file=sys.stderr, **kwargs)


def usage():
    eprint(
        "Usage: crop-pdf.py <input-pdf> <output-pdf> <trim-width-mm> "
        "<trim-height-mm> <bleed-mm> <offset-x-mm> <offset-y-mm>"
    )


def mm_to_pt(value: float) -> float:
    return value * POINTS_PER_MM


def number(value: str, name: str) -> float:
    try:
        return float(value)
    except ValueError:
        eprint(f"ERROR: {name} must be a number, got: {value}")
        sys.exit(2)


def main():
    if len(sys.argv) != 8:
        usage()
        sys.exit(2)

    input_pdf = Path(sys.argv[1])
    output_pdf = Path(sys.argv[2])
    trim_width_mm = number(sys.argv[3], "trim width")
    trim_height_mm = number(sys.argv[4], "trim height")
    bleed_mm = number(sys.argv[5], "bleed")
    offset_x_mm = number(sys.argv[6], "horizontal offset")
    offset_y_mm = number(sys.argv[7], "vertical offset")

    if not input_pdf.is_file():
        eprint(f"ERROR: input file not found: {input_pdf}")
        sys.exit(1)
    if trim_width_mm <= 0 or trim_height_mm <= 0:
        eprint("ERROR: trim width and height must be > 0")
        sys.exit(1)
    if bleed_mm < 0:
        eprint("ERROR: bleed must be >= 0")
        sys.exit(1)

    trim_width = mm_to_pt(trim_width_mm)
    trim_height = mm_to_pt(trim_height_mm)
    bleed = mm_to_pt(bleed_mm)
    offset_x = mm_to_pt(offset_x_mm)
    offset_y = mm_to_pt(offset_y_mm)
    media_width = trim_width + 2 * bleed
    media_height = trim_height + 2 * bleed

    with pikepdf.open(input_pdf) as pdf:
        page_count = len(pdf.pages)
        for index, page in enumerate(pdf.pages, start=1):
            media = [float(value) for value in page.MediaBox]
            if len(media) != 4:
                eprint(f"ERROR: invalid MediaBox on page {index}")
                sys.exit(1)
            x0, y0, x1, y1 = media
            width = x1 - x0
            height = y1 - y0
            if width < media_width or height < media_height:
                eprint(
                    f"ERROR: page {index} is too small for a {trim_width_mm:g} x "
                    f"{trim_height_mm:g} mm trim with {bleed_mm:g} mm bleed "
                    f"(available {width / POINTS_PER_MM:.2f} x "
                    f"{height / POINTS_PER_MM:.2f} mm)"
                )
                sys.exit(1)

            crop_x0 = x0 + (width - media_width) / 2 + offset_x
            crop_y0 = y0 + (height - media_height) / 2 + offset_y
            crop_x1 = crop_x0 + media_width
            crop_y1 = crop_y0 + media_height
            if crop_x0 < x0 or crop_y0 < y0 or crop_x1 > x1 or crop_y1 > y1:
                eprint(f"ERROR: crop with the requested offset falls outside page {index}")
                sys.exit(1)

            page.MediaBox = pikepdf.Array([crop_x0, crop_y0, crop_x1, crop_y1])
            page.CropBox = pikepdf.Array([crop_x0, crop_y0, crop_x1, crop_y1])
            page.BleedBox = pikepdf.Array([crop_x0, crop_y0, crop_x1, crop_y1])
            page.TrimBox = pikepdf.Array(
                [crop_x0 + bleed, crop_y0 + bleed, crop_x1 - bleed, crop_y1 - bleed]
            )

        pdf.save(output_pdf, min_version="1.6")

    print(f"Pages cropped: {page_count}")
    print(f"Trim size (mm): {trim_width_mm:g} x {trim_height_mm:g}")
    print(f"Bleed (mm): {bleed_mm:g}")
    print(f"Offset from centre (mm): {offset_x_mm:g} x {offset_y_mm:g}")
    print(f"Wrote {output_pdf}")


if __name__ == "__main__":
    main()
