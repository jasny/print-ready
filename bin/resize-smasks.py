#!/usr/bin/env python3
import re
import sys
from pathlib import Path

import pikepdf
from PIL import Image


def eprint(*args, **kwargs):
    print(*args, file=sys.stderr, **kwargs)


def usage():
    eprint("Usage: resize-smasks.py <input-pdf>")


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
    out_dir = Path("07-resize-smasks") / base_name
    out_dir.mkdir(parents=True, exist_ok=True)

    if not up_dir.is_dir() and not resize_dir.is_dir():
        eprint("ERROR: no upscaled or resized images found")
        sys.exit(1)

    def replacement_path(obj_id: int, gen: int) -> Path | None:
        name = f"obj-{obj_id}-{gen}.up.png"
        if (resize_dir / name).is_file():
            return resize_dir / name
        if (up_dir / name).is_file():
            return up_dir / name
        return None

    with pikepdf.open(input_pdf) as pdf:
        count = 0
        for obj in pdf.objects:
            if not isinstance(obj, pikepdf.Object):
                continue
            if not (isinstance(obj, pikepdf.Dictionary) or isinstance(obj, pikepdf.Stream)):
                continue
            if obj.get("/Subtype") != pikepdf.Name("/Image"):
                continue
            smask = obj.get("/SMask")
            if smask is None:
                continue

            ref = obj.objgen
            if ref is None:
                continue
            obj_id, gen = ref
            img_path = replacement_path(obj_id, gen)
            if img_path is None:
                continue

            try:
                with Image.open(img_path) as im:
                    target_size = im.size
            except Exception:
                continue

            smask_obj = smask
            try:
                pil_mask = pikepdf.PdfImage(smask_obj).as_pil_image()
            except Exception:
                continue

            if pil_mask.mode != "L":
                pil_mask = pil_mask.convert("L")

            if pil_mask.size != target_size:
                pil_mask = pil_mask.resize(target_size, Image.Resampling.LANCZOS)

            out_path = out_dir / f"obj-{smask_obj.objgen[0]}-{smask_obj.objgen[1]}.up.png"
            pil_mask.save(out_path)
            count += 1

        print(f"Wrote {count} smask images to {out_dir}")


if __name__ == "__main__":
    main()
