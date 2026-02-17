#!/usr/bin/env python3
import sys
from pathlib import Path

import pikepdf


def usage():
    print("Usage: set-pdfx-metadata.py <pdf> <icc-profile> <pdfx-version>", file=sys.stderr)


def main():
    if len(sys.argv) != 4:
        usage()
        return 2

    pdf_path = Path(sys.argv[1])
    icc_path = Path(sys.argv[2])
    pdfx_version = sys.argv[3]

    if not pdf_path.is_file():
        print(f"ERROR: file not found: {pdf_path}", file=sys.stderr)
        return 1
    if not icc_path.is_file():
        print(f"ERROR: ICC profile not found: {icc_path}", file=sys.stderr)
        return 1

    icc_bytes = icc_path.read_bytes()
    with pikepdf.open(pdf_path, allow_overwriting_input=True) as pdf:
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
        pdf.Root["/GTS_PDFXVersion"] = pikepdf.String(pdfx_version)
        pdf.Root["/GTS_PDFXConformance"] = pikepdf.String(pdfx_version)
        pdf.save(pdf_path)

    return 0


if __name__ == "__main__":
    raise SystemExit(main())
