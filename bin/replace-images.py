#!/usr/bin/env python3
import re
import subprocess
import sys
import tempfile
from pathlib import Path

import pikepdf
from PIL import Image


def eprint(*args, **kwargs):
    print(*args, file=sys.stderr, **kwargs)


def usage():
    eprint("Usage: replace-images.py <input-pdf>")


def render_eps_to_image(eps_path: Path, width: int, height: int) -> Image.Image:
    with tempfile.NamedTemporaryFile(suffix=".png", delete=False) as tmp:
        tmp_png = Path(tmp.name)
    try:
        # Render EPS to a high-resolution PNG, then resize to the exact object size.
        subprocess.run(
            [
                "gs",
                "-dSAFER",
                "-dBATCH",
                "-dNOPAUSE",
                "-sDEVICE=pngalpha",
                "-dEPSCrop",
                "-r600",
                f"-sOutputFile={tmp_png}",
                str(eps_path),
            ],
            check=True,
            stdout=subprocess.DEVNULL,
            stderr=subprocess.PIPE,
            text=True,
        )
        with Image.open(tmp_png) as im:
            return im.convert("RGBA").resize((width, height), Image.Resampling.LANCZOS)
    finally:
        try:
            tmp_png.unlink(missing_ok=True)
        except Exception:
            pass


def main():
    if len(sys.argv) != 2:
        usage()
        sys.exit(2)

    input_pdf = Path(sys.argv[1])
    if not input_pdf.is_file():
        eprint(f"ERROR: input file not found: {input_pdf}")
        sys.exit(1)

    base_name = input_pdf.stem
    up_dir = Path("04-upscale-images") / base_name
    resize_dir = Path("06-resize-images") / base_name
    smask_dir = Path("07-resize-smasks") / base_name
    output_dir = Path("08-replace-images")
    output_dir.mkdir(parents=True, exist_ok=True)

    out_pdf = output_dir / f"{base_name}.replaced.pdf"
    report_file = output_dir / f"{base_name}.replace.txt"

    if not up_dir.is_dir() and not resize_dir.is_dir():
        eprint("ERROR: no upscaled or resized images found")
        sys.exit(1)

    replacements = {}
    for src_dir in [up_dir, resize_dir]:
        if not src_dir.is_dir():
            continue
        for path in src_dir.iterdir():
            m = re.match(r"obj-(\d+)-(\d+)\.up\.(png|eps)$", path.name, flags=re.IGNORECASE)
            if not m:
                continue
            obj_id = int(m.group(1))
            gen = int(m.group(2))
            # prefer resized images over upscaled
            replacements[(obj_id, gen)] = path

    if not replacements:
        eprint("ERROR: no replacement images found")
        sys.exit(1)

    with pikepdf.open(input_pdf) as pdf, report_file.open("w") as rep:
        rep.write(f"Input: {input_pdf}\n")
        rep.write(f"Replacements: {len(replacements)}\n")
        smask_replaced = 0
        for (obj_id, gen), img_path in replacements.items():
            try:
                obj = pdf.get_object((obj_id, gen))
            except Exception:
                rep.write(f"SKIP obj {obj_id} {gen}: not found\n")
                continue

            prefer_gray = obj.get("/ColorSpace") == pikepdf.Name("/DeviceGray")
            im = None
            try:
                if img_path.suffix.lower() == ".eps":
                    im = render_eps_to_image(img_path, int(obj.Width), int(obj.Height))
                else:
                    with Image.open(img_path) as src_im:
                        im = src_im.copy()

                if prefer_gray:
                    out_mode = "L"
                    im = im.convert("L")
                else:
                    out_mode = "RGB"
                    im = im.convert("RGB")
                data = im.tobytes()
                obj.Type = pikepdf.Name("/XObject")
                obj.Subtype = pikepdf.Name("/Image")
                obj.Width = im.width
                obj.Height = im.height
                obj.BitsPerComponent = 8
                if out_mode == "L":
                    obj.ColorSpace = pikepdf.Name("/DeviceGray")
                else:
                    obj.ColorSpace = pikepdf.Name("/DeviceRGB")
                if "/Matte" in obj:
                    del obj["/Matte"]
                obj.write(data)
                rep.write(f"REPLACED obj {obj_id} {gen} -> {img_path}\n")
            finally:
                if im is not None:
                    im.close()

            # Replace smask if available
            smask_obj = obj.get("/SMask")
            if smask_obj is not None and smask_dir.is_dir():
                smask_path = smask_dir / f"obj-{smask_obj.objgen[0]}-{smask_obj.objgen[1]}.up.png"
                if smask_path.is_file():
                    with Image.open(smask_path) as sm:
                        if sm.mode != "L":
                            sm = sm.convert("L")
                        smask_obj.Type = pikepdf.Name("/XObject")
                        smask_obj.Subtype = pikepdf.Name("/Image")
                        smask_obj.Width = sm.width
                        smask_obj.Height = sm.height
                        smask_obj.BitsPerComponent = 8
                        smask_obj.ColorSpace = pikepdf.Name("/DeviceGray")
                        smask_obj.write(sm.tobytes())
                        smask_replaced += 1
                        rep.write(f"REPLACED smask {smask_obj.objgen[0]} {smask_obj.objgen[1]} -> {smask_path}\n")

        rep.write(f"SMasks replaced: {smask_replaced}\n")
        matte_removed = 0
        for obj in pdf.objects:
            try:
                if obj.get("/Subtype") == pikepdf.Name("/Image") and "/Matte" in obj:
                    del obj["/Matte"]
                    matte_removed += 1
            except Exception:
                continue
        if matte_removed:
            rep.write(f"Removed Matte entries: {matte_removed}\n")
        pdf.save(out_pdf)

    print(f"Wrote {out_pdf}")
    print(f"Wrote {report_file}")


if __name__ == "__main__":
    main()
