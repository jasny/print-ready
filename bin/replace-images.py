#!/usr/bin/env python3
import re
import subprocess
import sys
from pathlib import Path

import pikepdf
from pikepdf import Array
from PIL import Image


def eprint(*args, **kwargs):
    print(*args, file=sys.stderr, **kwargs)


def usage():
    eprint("Usage: replace-images.py <input-pdf>")


def build_form_from_eps(dest_pdf: pikepdf.Pdf, eps_path: Path):
    eps_pdf = eps_path.with_suffix(".tmp.pdf")
    try:
        subprocess.run(
            [
                "gs",
                "-dSAFER",
                "-dBATCH",
                "-dNOPAUSE",
                "-sDEVICE=pdfwrite",
                "-dEPSCrop",
                f"-sOutputFile={eps_pdf}",
                str(eps_path),
            ],
            check=True,
            stdout=subprocess.DEVNULL,
            stderr=subprocess.PIPE,
            text=True,
        )
        with pikepdf.open(eps_pdf) as src_pdf:
            form_stream = src_pdf.pages[0].as_form_xobject()
            imported = dest_pdf.copy_foreign(form_stream)
            bbox = imported.BBox
            w = max(0.001, float(bbox[2]) - float(bbox[0]))
            h = max(0.001, float(bbox[3]) - float(bbox[1]))
            # Make form behave like an image XObject (unit-square semantics).
            imported.Matrix = Array([1.0 / w, 0, 0, 1.0 / h, 0, 0])
            return imported
    finally:
        try:
            eps_pdf.unlink(missing_ok=True)
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

    out_pdf = output_dir / f"{base_name}.pdf"
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

            if img_path.suffix.lower() == ".eps":
                form_xobj = build_form_from_eps(pdf, img_path)
                obj.Type = pikepdf.Name("/XObject")
                obj.Subtype = pikepdf.Name("/Form")
                obj.FormType = 1
                obj.BBox = form_xobj.BBox
                obj.Matrix = form_xobj.Matrix
                if "/Resources" in form_xobj:
                    obj.Resources = form_xobj.Resources
                if "/Group" in form_xobj:
                    obj.Group = form_xobj.Group
                for key in ["/Width", "/Height", "/BitsPerComponent", "/ColorSpace", "/SMask", "/Matte", "/Filter", "/DecodeParms"]:
                    if key in obj:
                        del obj[key]
                obj.write(form_xobj.read_bytes())
                rep.write(f"REPLACED obj {obj_id} {gen} -> {img_path} (vector form)\n")
            else:
                prefer_gray = obj.get("/ColorSpace") == pikepdf.Name("/DeviceGray")
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
