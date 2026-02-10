#!/usr/bin/env bash
set -euo pipefail
export LC_ALL=C

usage() {
  echo "Usage: $0 <input-pdf>" >&2
}

if [[ $# -ne 1 ]]; then
  usage
  exit 2
fi

input_pdf="$1"
if [[ ! -f "$input_pdf" ]]; then
  echo "ERROR: input file not found: $input_pdf" >&2
  exit 1
fi

base_name="$(basename "$input_pdf")"
base_name="${base_name%.*}"

src_pdf="08-replace-images/${base_name}.replaced.pdf"
if [[ ! -f "$src_pdf" ]]; then
  # allow direct input if a different file is provided
  src_pdf="$input_pdf"
fi

output_dir="09-normalize-pdf"
report_file="${output_dir}/${base_name}.normalize.txt"
output_pdf="${output_dir}/${base_name}.print.pdf"

mkdir -p "$output_dir"

pdf_standard="${PDF_STANDARD:-PDF/X-1a}"
color_profile="${COLOR_PROFILE:-}"

{
  echo "Input: $src_pdf"
  echo "PDF_STANDARD: $pdf_standard"
  echo "COLOR_PROFILE: ${color_profile:-none}"
  echo "Started: $(date -u +%Y-%m-%dT%H:%M:%SZ)"
} > "$report_file"

# Basic normalization via Ghostscript. Produces a print-ready CMYK PDF.
# If COLOR_PROFILE is provided and exists, use it as output ICC.
if [[ -n "$color_profile" && -f "$color_profile" ]]; then
  gs \
    -dBATCH -dNOPAUSE -dSAFER \
    -sDEVICE=pdfwrite \
    -sOutputFile="$output_pdf" \
    -dPDFSETTINGS=/prepress \
    -dCompatibilityLevel=1.4 \
    -sProcessColorModel=DeviceCMYK \
    -sColorConversionStrategy=CMYK \
    -sColorConversionStrategyForImages=CMYK \
    -dOverrideICC \
    -sOutputICCProfile="$color_profile" \
    "$src_pdf"
else
  gs \
    -dBATCH -dNOPAUSE -dSAFER \
    -sDEVICE=pdfwrite \
    -sOutputFile="$output_pdf" \
    -dPDFSETTINGS=/prepress \
    -dCompatibilityLevel=1.4 \
    -sProcessColorModel=DeviceCMYK \
    -sColorConversionStrategy=CMYK \
    -sColorConversionStrategyForImages=CMYK \
    "$src_pdf"
fi

echo "Wrote: $output_pdf" >> "$report_file"

echo "Wrote $output_pdf"
echo "Wrote $report_file"
