#!/usr/bin/env bash
set -euo pipefail

usage() {
  echo "Usage: $0 <input-pdf> [start-step]" >&2
  echo "  start-step: 01..11 (default: 01)" >&2
}

if [[ $# -lt 1 || $# -gt 2 ]]; then
  usage
  exit 2
fi

input_pdf="$1"
if [[ ! -f "$input_pdf" ]]; then
  echo "ERROR: input file not found: $input_pdf" >&2
  exit 1
fi

start_step="${2:-01}"
if [[ ! "$start_step" =~ ^(0[1-9]|1[0-1])$ ]]; then
  echo "ERROR: invalid start-step '${start_step}'. Expected 01..11." >&2
  exit 2
fi

declare -A step_by_number=(
  ["01"]="./01-validate.sh"
  ["02"]="./02-analyze-dpi.sh"
  ["03"]="./03-extract-images.sh"
  ["04"]="./04-upscale-images.sh"
  ["05"]="./05-verify-images.sh"
  ["06"]="./06-resize-images.sh"
  ["07"]="./07-resize-smasks.sh"
  ["08"]="./08-replace-images.sh"
  ["09"]="./09-normalize-pdf.sh"
  ["10"]="./10-set-trim.sh"
  ["11"]="./11-pdf-x1a.sh"
)

steps=(
  "01"
  "02"
  "03"
  "04"
  "05"
  "06"
  "07"
  "08"
  "09"
  "10"
  "11"
)

run=false
for step_num in "${steps[@]}"; do
  if [[ "$step_num" == "$start_step" ]]; then
    run=true
  fi
  if [[ "$run" != "true" ]]; then
    continue
  fi
  step="${step_by_number[$step_num]}"
  echo "==> Running ${step} ${input_pdf}"
  "${step}" "${input_pdf}"
done

base_name="$(basename "$input_pdf")"
base_name="${base_name%.*}"
x1a_pdf="11-output/${base_name}.pdf"

echo "==> Running ./preflight.sh ${x1a_pdf}"
./preflight.sh "${x1a_pdf}"
