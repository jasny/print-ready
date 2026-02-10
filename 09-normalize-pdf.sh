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

pdf_standard="${PDF_STANDARD:-PDF/X-4}"
color_profile="${COLOR_PROFILE:-}"
normalize_dpi="${NORMALIZE_DPI:-${TARGET_DPI:-300}}"

{
  echo "Input: $src_pdf"
  echo "PDF_STANDARD: $pdf_standard"
  echo "COLOR_PROFILE: ${color_profile:-none}"
  echo "Started: $(date -u +%Y-%m-%dT%H:%M:%SZ)"
} > "$report_file"

# Basic normalization via Ghostscript. Produces a print-ready CMYK PDF.
# Disable all downsampling to preserve upscaled resolution.
gs_common=(
  -dBATCH -dNOPAUSE -dSAFER
  -sDEVICE=pdfwrite
  -sOutputFile="$output_pdf"
  -dColorImageResolution="$normalize_dpi"
  -dGrayImageResolution="$normalize_dpi"
  -dMonoImageResolution="$normalize_dpi"
  -r"$normalize_dpi"
)
gs_distiller='<< /DownsampleColorImages false /DownsampleGrayImages false /DownsampleMonoImages false >> setdistillerparams'
if [[ "$pdf_standard" == "PDF/X-1a" ]]; then
  gs_common+=(
    -dPDFX
    -dCompatibilityLevel=1.3
    -sProcessColorModel=DeviceCMYK
    -sColorConversionStrategy=CMYK
    -sColorConversionStrategyForImages=CMYK
  )
else
  gs_common+=(
    -dCompatibilityLevel=1.6
    -sColorConversionStrategy=LeaveColorUnchanged
    -sColorConversionStrategyForImages=LeaveColorUnchanged
  )
fi

# If COLOR_PROFILE is provided and exists, use it as output ICC.
if [[ -n "$color_profile" && -f "$color_profile" ]]; then
  gs "${gs_common[@]}" \
    -dOverrideICC \
    -sOutputICCProfile="$color_profile" \
    -c "$gs_distiller" \
    -f "$src_pdf"
else
  gs "${gs_common[@]}" \
    -c "$gs_distiller" \
    -f "$src_pdf"
fi

echo "Wrote: $output_pdf" >> "$report_file"

echo "Wrote $output_pdf"
echo "Wrote $report_file"
