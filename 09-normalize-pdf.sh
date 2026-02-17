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

src_pdf="08-replace-images/${base_name}.pdf"
if [[ ! -f "$src_pdf" ]]; then
  # allow direct input if a different file is provided
  src_pdf="$input_pdf"
fi

output_dir="09-normalize-pdf"
report_file="${output_dir}/${base_name}.normalize.txt"
output_pdf="${output_dir}/${base_name}.pdf"

mkdir -p "$output_dir"

pdf_standard="PDF/X-4"
default_profile="${DEFAULT_COLOR_PROFILE:-/usr/share/color/icc/colord/FOGRA39L_coated.icc}"
color_profile="${COLOR_PROFILE:-$default_profile}"

{
  echo "Input: $src_pdf"
  echo "PDF_STANDARD: $pdf_standard"
  echo "COLOR_PROFILE: ${color_profile:-none}"
  echo "Started: $(date -u +%Y-%m-%dT%H:%M:%SZ)"
} > "$report_file"

if [[ -z "$color_profile" || ! -f "$color_profile" ]]; then
  echo "ERROR: COLOR_PROFILE not found: $color_profile" >&2
  exit 1
fi
color_profile="$(readlink -f "$color_profile")"
if [[ ! -x ./.venv/bin/python ]]; then
  echo "ERROR: venv missing. Run ./install.sh first." >&2
  exit 1
fi
. .venv/bin/activate
python ./bin/normalize-pdf.py "$src_pdf" "$output_pdf" "$color_profile" "$pdf_standard"
python ./bin/rewrite-page-rgb.py "$output_pdf" "$color_profile" "${DARK_RGB_CMYK:-0 0 0 1}"

echo "Wrote: $output_pdf" >> "$report_file"

echo "Wrote $output_pdf"
echo "Wrote $report_file"
