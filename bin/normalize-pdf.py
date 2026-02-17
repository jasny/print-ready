#!/usr/bin/env python3
import re
import sys
from pathlib import Path
import os
import tempfile

import pikepdf
from PIL import Image
from PIL import ImageCms


def eprint(*args, **kwargs):
    print(*args, file=sys.stderr, **kwargs)


def usage():
    eprint("Usage: normalize-pdf.py <input-pdf> <output-pdf> <icc-profile> <pdf-standard>")


def format_pdf_num(v: float) -> str:
    s = f"{v:.4f}"
    s = s.rstrip("0").rstrip(".")
    return s if s else "0"


def is_near_black(r: float, g: float, b: float) -> bool:
    # Treat very dark RGB as typography black and force rich black.
    if max(r, g, b) <= 0.12:
        return True
    # Also catch near-neutral dark values.
    return abs(r - g) <= 0.03 and abs(g - b) <= 0.03 and max(r, g, b) <= 0.25


def parse_cmyk_override(raw: str):
    parts = raw.strip().split()
    if len(parts) != 4:
        raise ValueError("expected four CMYK values")
    vals = [float(x) for x in parts]
    for v in vals:
        if v < 0.0 or v > 1.0:
            raise ValueError("CMYK values must be in [0,1]")
    return tuple(vals)


def rgb_to_cmyk_tuple(r: float, g: float, b: float, srgb_profile, out_profile, forced_black):
    if is_near_black(r, g, b):
        return forced_black, True
    img = Image.new("RGB", (1, 1), (int(round(r * 255)), int(round(g * 255)), int(round(b * 255))))
    cmyk = ImageCms.profileToProfile(img, srgb_profile, out_profile, outputMode="CMYK")
    c, m, y, k = cmyk.getpixel((0, 0))
    return (c / 255.0, m / 255.0, y / 255.0, k / 255.0), False


def rewrite_rgb_operators(stream_bytes: bytes, srgb_profile, out_profile, forced_black):
    # Match: "<r> <g> <b> rg" or "... RG"
    pattern = re.compile(
        rb"(?P<prefix>(^|[\s\[\(]))"
        rb"(?P<r>[+-]?(?:\d+(?:\.\d+)?|\.\d+))\s+"
        rb"(?P<g>[+-]?(?:\d+(?:\.\d+)?|\.\d+))\s+"
        rb"(?P<b>[+-]?(?:\d+(?:\.\d+)?|\.\d+))\s+"
        rb"(?P<op>rg|RG)(?P<suffix>(?=$|[\s\]\)\<\>]))"
    )
    cache = {}
    converted_ops = 0
    deep_black_ops = 0

    def repl(match):
        nonlocal converted_ops, deep_black_ops
        r = float(match.group("r"))
        g = float(match.group("g"))
        b = float(match.group("b"))
        key = (round(r, 6), round(g, 6), round(b, 6))
        if key not in cache:
            cache[key] = rgb_to_cmyk_tuple(r, g, b, srgb_profile, out_profile, forced_black)
        (c, m, y, k), forced_black = cache[key]
        if forced_black:
            deep_black_ops += 1
        converted_ops += 1
        op = b"k" if match.group("op") == b"rg" else b"K"
        repl_txt = (
            f"{format_pdf_num(c)} {format_pdf_num(m)} {format_pdf_num(y)} {format_pdf_num(k)} ".encode("ascii")
            + op
        )
        return match.group("prefix") + repl_txt + match.group("suffix")

    new_bytes = pattern.sub(repl, stream_bytes)
    return new_bytes, converted_ops, deep_black_ops


def main():
    if len(sys.argv) != 5:
        usage()
        sys.exit(2)

    input_pdf = Path(sys.argv[1])
    output_pdf = Path(sys.argv[2])
    icc_profile = Path(sys.argv[3])
    pdf_standard = sys.argv[4]

    if not input_pdf.is_file():
        eprint(f"ERROR: input file not found: {input_pdf}")
        sys.exit(1)
    if not icc_profile.is_file():
        eprint(f"ERROR: ICC profile not found: {icc_profile}")
        sys.exit(1)

    icc_bytes = icc_profile.read_bytes()
    out_profile = ImageCms.ImageCmsProfile(str(icc_profile))
    srgb_profile = ImageCms.createProfile("sRGB")
    forced_black = parse_cmyk_override(os.getenv("DARK_RGB_CMYK", "0 0 0 1"))

    stream_rgb_ops = 0
    stream_deep_black_ops = 0

    with pikepdf.open(input_pdf) as pdf:
        objects = list(pdf.objects)
        icc_stream = pdf.make_stream(icc_bytes)
        icc_stream["/N"] = 4

        output_intent = pdf.make_indirect(
            {
                "/Type": pikepdf.Name("/OutputIntent"),
                "/S": pikepdf.Name("/GTS_PDFX"),
                "/OutputConditionIdentifier": "Coated FOGRA39 (ISO 12647-2:2004)",
                "/Info": "Coated FOGRA39 (ISO 12647-2:2004)",
                "/DestOutputProfile": icc_stream,
            }
        )

        pdf.Root["/OutputIntents"] = pikepdf.Array([output_intent])
        pdf.Root["/GTS_PDFXVersion"] = pikepdf.String(pdf_standard)
        pdf.Root["/GTS_PDFXConformance"] = pikepdf.String(pdf_standard)

        converted = 0
        for obj in objects:
            try:
                if obj.get("/Subtype") != pikepdf.Name("/Image"):
                    continue
                colorspace = obj.get("/ColorSpace")
                if colorspace is None:
                    continue
                is_rgb = colorspace == pikepdf.Name("/DeviceRGB")
                if not is_rgb and isinstance(colorspace, pikepdf.Array):
                    if len(colorspace) >= 2 and colorspace[0] == pikepdf.Name("/ICCBased"):
                        icc = colorspace[1]
                        if icc.get("/N") == 3:
                            is_rgb = True
                if not is_rgb:
                    continue

                width = int(obj.get("/Width"))
                height = int(obj.get("/Height"))
                bpc = int(obj.get("/BitsPerComponent", 8))
                if bpc != 8:
                    # Keep non-8-bit images unchanged to avoid introducing artifacts.
                    continue

                decoded = obj.read_bytes()
                expected_len = width * height * 3
                if len(decoded) != expected_len:
                    # Some streams decode through predictors/alternate layouts.
                    # Skip instead of risking alpha/edge corruption from lossy fallbacks.
                    continue

                img = Image.frombytes("RGB", (width, height), decoded)

                cmyk = ImageCms.profileToProfile(
                    img,
                    srgb_profile,
                    out_profile,
                    outputMode="CMYK",
                )

                obj.ColorSpace = pikepdf.Name("/DeviceCMYK")
                obj.BitsPerComponent = 8
                obj.Width = cmyk.width
                obj.Height = cmyk.height
                if "/SMask" in obj:
                    # Avoid interpolation mismatch between image and soft-mask, which
                    # can show as thin halo/border lines in some PDF renderers.
                    obj["/Interpolate"] = False
                if "/Matte" in obj:
                    del obj["/Matte"]
                obj.write(cmyk.tobytes())
                converted += 1
            except Exception:
                continue

        nonimage_converted = 0
        for obj in objects:
            try:
                if obj.get("/Subtype") == pikepdf.Name("/Image"):
                    continue
            except Exception:
                pass

            if not isinstance(obj, pikepdf.Dictionary):
                continue

            # Only convert transparency group colorspace.
            # Broad dictionary colorspace rewrites can break shading/function consistency.
            group = obj.get("/Group")
            if isinstance(group, pikepdf.Dictionary) and "/CS" in group:
                if group["/CS"] == pikepdf.Name("/DeviceRGB") or group["/CS"] == pikepdf.Name("/CalRGB"):
                    group["/CS"] = pikepdf.Name("/DeviceCMYK")
                    nonimage_converted += 1

        if converted:
            eprint(f"Converted RGB images: {converted}")
        if nonimage_converted:
            eprint(f"Converted RGB non-image colorspaces: {nonimage_converted}")

        with tempfile.NamedTemporaryFile(suffix=".pdf", delete=False) as tmp:
            tmp_pdf = Path(tmp.name)
        pdf.save(tmp_pdf, min_version="1.6")

    # Second pass: rewrite RGB paint operators in non-image content streams
    # (page contents, form xobjects, etc.).
    with pikepdf.open(tmp_pdf) as pdf2:
        seen = set()
        for page in pdf2.pages:
            contents = page.get("/Contents")
            if contents is None:
                continue
            if isinstance(contents, pikepdf.Array):
                content_refs = contents
            else:
                content_refs = [contents]
            for ref in content_refs:
                try:
                    og = ref.objgen
                    if og in seen:
                        continue
                    seen.add(og)
                    stream_obj = ref
                    raw = stream_obj.read_bytes()
                    rewritten, changed, deep_black = rewrite_rgb_operators(raw, srgb_profile, out_profile, forced_black)
                    if changed > 0:
                        stream_obj.write(rewritten)
                        stream_rgb_ops += changed
                        stream_deep_black_ops += deep_black
                except Exception:
                    continue
        pdf2.save(output_pdf, min_version="1.6")

    try:
        tmp_pdf.unlink(missing_ok=True)
    except Exception:
        pass

    if stream_rgb_ops:
        eprint(f"Converted RGB content operators: {stream_rgb_ops}")
    if stream_deep_black_ops:
        eprint(f"Forced deep black operators: {stream_deep_black_ops}")

    print(f"Wrote {output_pdf}")


if __name__ == "__main__":
    main()
