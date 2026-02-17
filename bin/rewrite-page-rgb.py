#!/usr/bin/env python3
import re
import sys
from pathlib import Path

import pikepdf
from PIL import Image
from PIL import ImageCms


def usage():
    print("Usage: rewrite-page-rgb.py <pdf> <icc-profile> [forced-cmyk]", file=sys.stderr)


def format_pdf_num(v: float) -> str:
    s = f"{v:.4f}".rstrip("0").rstrip(".")
    return s if s else "0"


def is_near_black(r: float, g: float, b: float) -> bool:
    if max(r, g, b) <= 0.12:
        return True
    return abs(r - g) <= 0.03 and abs(g - b) <= 0.03 and max(r, g, b) <= 0.25


def parse_cmyk(raw: str):
    vals = [float(x) for x in raw.split()]
    if len(vals) != 4 or any(v < 0 or v > 1 for v in vals):
        raise ValueError("forced-cmyk must be four values in [0,1]")
    return tuple(vals)


def rgb_to_cmyk_tuple(r: float, g: float, b: float, srgb_profile, out_profile):
    img = Image.new("RGB", (1, 1), (int(round(r * 255)), int(round(g * 255)), int(round(b * 255))))
    cmyk = ImageCms.profileToProfile(img, srgb_profile, out_profile, outputMode="CMYK")
    c, m, y, k = cmyk.getpixel((0, 0))
    return (c / 255.0, m / 255.0, y / 255.0, k / 255.0)


def is_neutral_rgb_triplet(arr, tol=1e-6):
    if not isinstance(arr, pikepdf.Array) or len(arr) != 3:
        return False
    r, g, b = float(arr[0]), float(arr[1]), float(arr[2])
    return abs(r - g) <= tol and abs(g - b) <= tol


def main():
    if len(sys.argv) not in (3, 4):
        usage()
        sys.exit(2)

    pdf_path = Path(sys.argv[1])
    icc_path = Path(sys.argv[2])
    forced_black = parse_cmyk(sys.argv[3] if len(sys.argv) == 4 else "0 0 0 1")

    if not pdf_path.is_file():
        print(f"ERROR: pdf not found: {pdf_path}", file=sys.stderr)
        sys.exit(1)
    if not icc_path.is_file():
        print(f"ERROR: ICC not found: {icc_path}", file=sys.stderr)
        sys.exit(1)

    srgb_profile = ImageCms.createProfile("sRGB")
    out_profile = ImageCms.ImageCmsProfile(str(icc_path))

    pattern = re.compile(
        rb"(?P<prefix>(^|[\s\[\(]))"
        rb"(?P<r>[+-]?(?:\d+(?:\.\d+)?|\.\d+))\s+"
        rb"(?P<g>[+-]?(?:\d+(?:\.\d+)?|\.\d+))\s+"
        rb"(?P<b>[+-]?(?:\d+(?:\.\d+)?|\.\d+))\s+"
        rb"(?P<op>rg|RG)(?P<suffix>(?=$|[\s\]\)\<\>]))"
    )

    converted_ops = 0
    forced_ops = 0
    converted_transparency_cs = 0
    converted_shading_cs = 0
    converted_shading_functions = 0
    with pikepdf.open(pdf_path, allow_overwriting_input=True) as pdf:
        seen = set()
        for page in pdf.pages:
            contents = page.get("/Contents")
            if contents is None:
                continue
            refs = contents if isinstance(contents, pikepdf.Array) else [contents]
            for ref in refs:
                try:
                    og = ref.objgen
                    if og in seen:
                        continue
                    seen.add(og)
                    raw = ref.read_bytes()
                except Exception:
                    continue

                cache = {}

                def repl(match):
                    nonlocal converted_ops, forced_ops
                    r = float(match.group("r"))
                    g = float(match.group("g"))
                    b = float(match.group("b"))
                    key = (round(r, 6), round(g, 6), round(b, 6))
                    if key not in cache:
                        if is_near_black(r, g, b):
                            cache[key] = (forced_black, True)
                        else:
                            img = Image.new("RGB", (1, 1), (int(round(r * 255)), int(round(g * 255)), int(round(b * 255))))
                            cmyk = ImageCms.profileToProfile(img, srgb_profile, out_profile, outputMode="CMYK")
                            c, m, y, k = cmyk.getpixel((0, 0))
                            cache[key] = ((c / 255.0, m / 255.0, y / 255.0, k / 255.0), False)
                    (c, m, y, k), is_forced = cache[key]
                    if is_forced:
                        forced_ops += 1
                    converted_ops += 1
                    op = b"k" if match.group("op") == b"rg" else b"K"
                    return (
                        match.group("prefix")
                        + f"{format_pdf_num(c)} {format_pdf_num(m)} {format_pdf_num(y)} {format_pdf_num(k)} ".encode("ascii")
                        + op
                        + match.group("suffix")
                    )

                rewritten = pattern.sub(repl, raw)
                if rewritten != raw:
                    ref.write(rewritten)

        function_seen_cmyk = set()
        function_seen_gray = set()

        def function_can_be_gray(fn_obj):
            if not isinstance(fn_obj, pikepdf.Dictionary):
                return False
            ftype = int(fn_obj.get("/FunctionType", -1))
            if ftype == 2:
                for key in ("/C0", "/C1"):
                    arr = fn_obj.get(key)
                    if isinstance(arr, pikepdf.Array) and len(arr) == 3 and not is_neutral_rgb_triplet(arr):
                        return False
                return True
            if ftype == 3:
                sub_fns = fn_obj.get("/Functions")
                if not isinstance(sub_fns, pikepdf.Array):
                    return False
                for sub_fn in sub_fns:
                    if not function_can_be_gray(sub_fn):
                        return False
                return True
            return False

        def convert_function_cmyk(fn_obj):
            nonlocal converted_shading_functions
            if not isinstance(fn_obj, pikepdf.Dictionary):
                return
            if fn_obj.is_indirect:
                og = fn_obj.objgen
                if og in function_seen_cmyk:
                    return
                function_seen_cmyk.add(og)

            ftype = int(fn_obj.get("/FunctionType", -1))
            if ftype == 2:
                changed = False
                for key in ("/C0", "/C1"):
                    arr = fn_obj.get(key)
                    if isinstance(arr, pikepdf.Array) and len(arr) == 3:
                        r, g, b = float(arr[0]), float(arr[1]), float(arr[2])
                        c, m, y, k = rgb_to_cmyk_tuple(r, g, b, srgb_profile, out_profile)
                        fn_obj[key] = pikepdf.Array([c, m, y, k])
                        changed = True
                if changed:
                    converted_shading_functions += 1
            elif ftype == 3:
                sub_fns = fn_obj.get("/Functions")
                if isinstance(sub_fns, pikepdf.Array):
                    for sub_fn in sub_fns:
                        convert_function_cmyk(sub_fn)

        def convert_function_gray(fn_obj):
            nonlocal converted_shading_functions
            if not isinstance(fn_obj, pikepdf.Dictionary):
                return
            if fn_obj.is_indirect:
                og = fn_obj.objgen
                if og in function_seen_gray:
                    return
                function_seen_gray.add(og)

            ftype = int(fn_obj.get("/FunctionType", -1))
            if ftype == 2:
                changed = False
                for key in ("/C0", "/C1"):
                    arr = fn_obj.get(key)
                    if isinstance(arr, pikepdf.Array) and len(arr) == 3:
                        gray = float(arr[0])
                        fn_obj[key] = pikepdf.Array([gray])
                        changed = True
                if changed:
                    converted_shading_functions += 1
            elif ftype == 3:
                sub_fns = fn_obj.get("/Functions")
                if isinstance(sub_fns, pikepdf.Array):
                    for sub_fn in sub_fns:
                        convert_function_gray(sub_fn)

        # Normalize transparency groups that still declare RGB.
        for obj in pdf.objects:
            if not isinstance(obj, pikepdf.Dictionary):
                continue
            if obj.get("/S") == pikepdf.Name("/Transparency") and obj.get("/CS") == pikepdf.Name("/DeviceRGB"):
                obj["/CS"] = pikepdf.Name("/DeviceCMYK")
                converted_transparency_cs += 1
            shading = obj.get("/Shading")
            if isinstance(shading, pikepdf.Dictionary):
                if shading.get("/ColorSpace") in (pikepdf.Name("/DeviceRGB"), pikepdf.Name("/CalRGB")):
                    fn_obj = shading.get("/Function")
                    if function_can_be_gray(fn_obj):
                        shading["/ColorSpace"] = pikepdf.Name("/DeviceGray")
                        convert_function_gray(fn_obj)
                    else:
                        shading["/ColorSpace"] = pikepdf.Name("/DeviceCMYK")
                        convert_function_cmyk(fn_obj)
                    converted_shading_cs += 1

        pdf.save(pdf_path, min_version="1.6")

    if converted_ops:
        print(f"Converted RGB content operators: {converted_ops}", file=sys.stderr)
    if forced_ops:
        print(f"Forced dark operators: {forced_ops}", file=sys.stderr)
    if converted_transparency_cs:
        print(f"Converted transparency groups RGB->CMYK: {converted_transparency_cs}", file=sys.stderr)
    if converted_shading_cs:
        print(f"Converted shading colorspaces RGB->CMYK: {converted_shading_cs}", file=sys.stderr)
    if converted_shading_functions:
        print(f"Converted shading functions RGB->CMYK: {converted_shading_functions}", file=sys.stderr)


if __name__ == "__main__":
    main()
