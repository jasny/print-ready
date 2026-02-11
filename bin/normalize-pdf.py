#!/usr/bin/env python3
import sys
from pathlib import Path

import pikepdf
from pikepdf import PdfImage
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

        pdf.save(output_pdf, min_version="1.6")

    print(f"Wrote {output_pdf}")


if __name__ == "__main__":
    main()
