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

src_pdf="09-normalize-pdf/${base_name}.print.pdf"
if [[ ! -f "$src_pdf" ]]; then
  src_pdf="$input_pdf"
fi

output_dir="10-output"
output_pdf="${output_dir}/${base_name}.print.pdf"
report_file="${output_dir}/${base_name}.trim.txt"
trim_margin_mm="${TRIM_MARGIN_MM:-3}"

mkdir -p "$output_dir"

if [[ ! -x ./.venv/bin/python ]]; then
  echo "ERROR: venv missing. Run ./00-install.sh first." >&2
  exit 1
fi

{
  echo "Input: $src_pdf"
  echo "Trim margin (mm): $trim_margin_mm"
  echo "Started: $(date -u +%Y-%m-%dT%H:%M:%SZ)"
} > "$report_file"

. .venv/bin/activate
python ./bin/set-trim-boxes.py "$src_pdf" "$output_pdf" "$trim_margin_mm" >> "$report_file"

echo "Wrote $output_pdf"
echo "Wrote $report_file"
