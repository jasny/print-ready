#!/usr/bin/env python3
import re
import sys
from pathlib import Path

import pikepdf
from pikepdf import PdfImage
from PIL import Image
from PIL import ImageCms


def eprint(*args, **kwargs):
    print(*args, file=sys.stderr, **kwargs)


def usage():
    eprint("Usage: normalize-pdf.py <input-pdf> <output-pdf> <icc-profile> <pdf-standard>")


def is_rgb_colorspace(value) -> bool:
    if value == pikepdf.Name("/DeviceRGB") or value == pikepdf.Name("/CalRGB"):
        return True
    if isinstance(value, pikepdf.Array) and len(value) >= 2 and value[0] == pikepdf.Name("/ICCBased"):
        try:
            icc = value[1]
            return icc.get("/N") == 3
        except Exception:
            return False
    return False


def convert_colorspace_entry(value):
    if is_rgb_colorspace(value):
        return pikepdf.Name("/DeviceCMYK"), 1
    return value, 0


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


def rgb_to_cmyk_tuple(r: float, g: float, b: float, srgb_profile, out_profile):
    if is_near_black(r, g, b):
        return (0.5, 0.4, 0.4, 1.0), True
    img = Image.new("RGB", (1, 1), (int(round(r * 255)), int(round(g * 255)), int(round(b * 255))))
    cmyk = ImageCms.profileToProfile(img, srgb_profile, out_profile, outputMode="CMYK")
    c, m, y, k = cmyk.getpixel((0, 0))
    return (c / 255.0, m / 255.0, y / 255.0, k / 255.0), False


def rewrite_rgb_operators(stream_bytes: bytes, srgb_profile, out_profile):
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
            cache[key] = rgb_to_cmyk_tuple(r, g, b, srgb_profile, out_profile)
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

    with pikepdf.open(input_pdf) as pdf:
        icc_stream = pdf.make_stream(icc_bytes)
        icc_stream["/N"] = 4

        output_intent = pdf.make_indirect(
            {
                "/Type": pikepdf.Name("/OutputIntent"),
                "/S": pikepdf.Name("/GTS_PDFX"),
                "/OutputConditionIdentifier": "Uncoated FOGRA29 (ISO 12647-2:2004)",
                "/Info": "Uncoated FOGRA29 (ISO 12647-2:2004)",
                "/DestOutputProfile": icc_stream,
            }
        )

        pdf.Root["/OutputIntents"] = pikepdf.Array([output_intent])
        pdf.Root["/GTS_PDFXVersion"] = pikepdf.String(pdf_standard)
        pdf.Root["/GTS_PDFXConformance"] = pikepdf.String(pdf_standard)

        converted = 0
        for obj in pdf.objects:
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

                img = PdfImage(obj).as_pil_image()
                if img.mode not in ("RGB", "RGBA"):
                    img = img.convert("RGB")
                if img.mode == "RGBA":
                    img = img.convert("RGB")

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
                if "/Matte" in obj:
                    del obj["/Matte"]
                obj.write(cmyk.tobytes())
                converted += 1
            except Exception:
                continue

        nonimage_converted = 0
        for obj in pdf.objects:
            try:
                if obj.get("/Subtype") == pikepdf.Name("/Image"):
                    continue
            except Exception:
                pass

            if not isinstance(obj, pikepdf.Dictionary):
                continue

            # Common non-image colorspace keys.
            for cs_key in ("/CS", "/ColorSpace"):
                if cs_key in obj:
                    new_cs, changed = convert_colorspace_entry(obj[cs_key])
                    if changed:
                        obj[cs_key] = new_cs
                        nonimage_converted += changed

            # Page/Form transparency group colorspace.
            group = obj.get("/Group")
            if isinstance(group, pikepdf.Dictionary) and "/CS" in group:
                new_cs, changed = convert_colorspace_entry(group["/CS"])
                if changed:
                    group["/CS"] = new_cs
                    nonimage_converted += changed

            # Resource ColorSpace dictionary values.
            resources = obj.get("/Resources")
            if isinstance(resources, pikepdf.Dictionary):
                res_cs = resources.get("/ColorSpace")
                if isinstance(res_cs, pikepdf.Dictionary):
                    for name in list(res_cs.keys()):
                        new_cs, changed = convert_colorspace_entry(res_cs[name])
                        if changed:
                            res_cs[name] = new_cs
                            nonimage_converted += changed

                # Resource Shading dictionary entries.
                res_shading = resources.get("/Shading")
                if isinstance(res_shading, pikepdf.Dictionary):
                    for name in list(res_shading.keys()):
                        shading = res_shading[name]
                        if isinstance(shading, pikepdf.Dictionary) and "/ColorSpace" in shading:
                            new_cs, changed = convert_colorspace_entry(shading["/ColorSpace"])
                            if changed:
                                shading["/ColorSpace"] = new_cs
                                nonimage_converted += changed

            # Direct shading dictionary on this object.
            shading = obj.get("/Shading")
            if isinstance(shading, pikepdf.Dictionary) and "/ColorSpace" in shading:
                new_cs, changed = convert_colorspace_entry(shading["/ColorSpace"])
                if changed:
                    shading["/ColorSpace"] = new_cs
                    nonimage_converted += changed

        if converted:
            eprint(f"Converted RGB images: {converted}")
        if nonimage_converted:
            eprint(f"Converted RGB non-image colorspaces: {nonimage_converted}")

        # Rewrite RGB paint operators in page content streams.
        stream_rgb_ops = 0
        stream_deep_black_ops = 0
        content_stream_ids = set()
        for obj in pdf.objects:
            if not isinstance(obj, pikepdf.Dictionary):
                continue
            if obj.get("/Type") != pikepdf.Name("/Page"):
                continue
            contents = obj.get("/Contents")
            if contents is None:
                continue
            if isinstance(contents, pikepdf.Array):
                for c in contents:
                    try:
                        content_stream_ids.add(c.objgen)
                    except Exception:
                        continue
            else:
                try:
                    content_stream_ids.add(contents.objgen)
                except Exception:
                    continue

        for obj_id, gen in content_stream_ids:
            try:
                stream_obj = pdf.get_object((obj_id, gen))
                raw = stream_obj.read_bytes()
                rewritten, changed, deep_black = rewrite_rgb_operators(raw, srgb_profile, out_profile)
                if changed > 0:
                    stream_obj.write(rewritten)
                    stream_rgb_ops += changed
                    stream_deep_black_ops += deep_black
            except Exception:
                continue
        if stream_rgb_ops:
            eprint(f"Converted RGB content operators: {stream_rgb_ops}")
        if stream_deep_black_ops:
            eprint(f"Forced deep black operators: {stream_deep_black_ops}")

        pdf.save(output_pdf, min_version="1.6")

    print(f"Wrote {output_pdf}")


if __name__ == "__main__":
    main()
