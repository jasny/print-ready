#!/usr/bin/env bash
set -euo pipefail

usage() {
  echo "Usage: $0 <input-pdf> [output-pdf]" >&2
}

if [[ $# -lt 1 || $# -gt 2 ]]; then
  usage
  exit 2
fi

in_pdf="$1"
if [[ ! -f "$in_pdf" ]]; then
  echo "ERROR: input file not found: $in_pdf" >&2
  exit 1
fi

if [[ $# -eq 2 ]]; then
  out_pdf="$2"
else
  out_pdf="${in_pdf%.pdf}.x1a.pdf"
fi

color_profile="${COLOR_PROFILE:-/usr/share/color/icc/colord/FOGRA39L_coated.icc}"
if [[ ! -f "$color_profile" ]]; then
  echo "ERROR: ICC profile not found: $color_profile" >&2
  exit 1
fi

if ! command -v gs >/dev/null 2>&1; then
  echo "ERROR: ghostscript (gs) not found. Run ./00-install.sh" >&2
  exit 1
fi

mkdir -p "$(dirname "$out_pdf")"

echo "Input : $in_pdf"
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
  -f "$in_pdf"

if command -v qpdf >/dev/null 2>&1; then
  echo "qpdf check:"
  qpdf --check "$out_pdf"
fi

echo "Wrote $out_pdf"
