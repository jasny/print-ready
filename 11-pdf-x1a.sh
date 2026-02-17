#!/usr/bin/env bash
set -euo pipefail

usage() {
  echo "Usage: $0 <input-pdf>" >&2
}

if [[ $# -ne 1 ]]; then
  usage
  exit 2
fi

in_pdf="$1"
if [[ ! -f "$in_pdf" ]]; then
  echo "ERROR: input file not found: $in_pdf" >&2
  exit 1
fi

base_name="$(basename "$in_pdf")"
base_name="${base_name%.*}"

src_pdf="10-pdf-x4/${base_name}.pdf"
if [[ ! -f "$src_pdf" ]]; then
  src_pdf="$in_pdf"
fi

out_dir="11-output"
out_pdf="${out_dir}/${base_name}.pdf"

color_profile="${COLOR_PROFILE:-/usr/share/color/icc/colord/FOGRA39L_coated.icc}"
if [[ ! -f "$color_profile" ]]; then
  echo "ERROR: ICC profile not found: $color_profile" >&2
  exit 1
fi

if ! command -v gs >/dev/null 2>&1; then
  echo "ERROR: ghostscript (gs) not found. Run ./00-install.sh" >&2
  exit 1
fi

mkdir -p "$out_dir"

echo "Input : $src_pdf"
echo "Output: $out_pdf"
echo "Profile: $color_profile"

gs \
  -dBATCH -dNOPAUSE -dSAFER \
  -sDEVICE=pdfwrite \
  -dPDFX \
  -dCompatibilityLevel=1.3 \
  -sProcessColorModel=DeviceCMYK \
  -sColorConversionStrategy=CMYK \
  -sColorConversionStrategyForImages=CMYK \
  -dOverrideICC \
  -sOutputICCProfile="$color_profile" \
  -dAutoRotatePages=/None \
  -dEmbedAllFonts=true \
  -dSubsetFonts=true \
  -dDownsampleColorImages=false \
  -dDownsampleGrayImages=false \
  -dDownsampleMonoImages=false \
  -sOutputFile="$out_pdf" \
  -f "$src_pdf"

if [[ ! -x ./.venv/bin/python ]]; then
  echo "ERROR: venv missing. Run ./00-install.sh first." >&2
  exit 1
fi
. .venv/bin/activate
output_condition="${OUTPUT_CONDITION_IDENTIFIER:-$(basename "${color_profile%.*}")}"
python ./bin/set-pdfx-metadata.py "$out_pdf" "$color_profile" "PDF/X-1a:2001" "$output_condition"

if command -v qpdf >/dev/null 2>&1; then
  echo "qpdf check:"
  qpdf --check "$out_pdf"
fi

echo "Wrote $out_pdf"
