#!/usr/bin/env bash
set -euo pipefail
export LC_ALL=C

usage() {
  echo "Usage: $0 <input-pdf> <trim-width-mm> <trim-height-mm> [offset-x-mm offset-y-mm]" >&2
  echo "Creates a centered crop with ${BLEED_MM:-3} mm bleed on every side." >&2
  echo "Positive offsets move the crop right and up." >&2
}

if [[ $# -ne 3 && $# -ne 5 ]]; then
  usage
  exit 2
fi

input_pdf="$1"
trim_width_mm="$2"
trim_height_mm="$3"
offset_x_mm="${4:-0}"
offset_y_mm="${5:-0}"

if [[ ! -f "$input_pdf" ]]; then
  echo "ERROR: input file not found: $input_pdf" >&2
  exit 1
fi
if [[ ! -x ./.venv/bin/python ]]; then
  echo "ERROR: venv missing. Run ./install.sh first." >&2
  exit 1
fi

base_name="$(basename "$input_pdf")"
base_name="${base_name%.*}"
output_dir="09-normalize-pdf"
output_pdf="${output_dir}/${base_name}-cropped.pdf"
report_file="${output_dir}/${base_name}-cropped.crop.txt"
bleed_mm="${BLEED_MM:-3}"

mkdir -p "$output_dir"

{
  echo "Input: $input_pdf"
  echo "Output: $output_pdf"
  echo "Trim size (mm): ${trim_width_mm} x ${trim_height_mm}"
  echo "Bleed (mm): $bleed_mm"
  echo "Offset from centre (mm): ${offset_x_mm} x ${offset_y_mm}"
  echo "Started: $(date -u +%Y-%m-%dT%H:%M:%SZ)"
} > "$report_file"

. .venv/bin/activate
python ./bin/crop-pdf.py \
  "$input_pdf" "$output_pdf" \
  "$trim_width_mm" "$trim_height_mm" "$bleed_mm" \
  "$offset_x_mm" "$offset_y_mm" >> "$report_file"

echo "Wrote $output_pdf"
echo "Wrote $report_file"
