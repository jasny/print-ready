#!/usr/bin/env bash
set -euo pipefail

usage() {
  echo "Usage: $0 <input-pdf> [start-step]" >&2
  echo "       $0 --all" >&2
  echo "  start-step: 01..11 (default: 01)" >&2
  echo "  --all: convert every PDF in 00-input/ without an 11-output PDF" >&2
}

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

convert() {
  local input_pdf="$1"
  local start_step="${2:-01}"
  local step_num
  local step
  local run=false
  local base_name
  local x1a_pdf

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
}

if [[ $# -eq 1 && "$1" == "--all" ]]; then
  found_input=false
  while IFS= read -r -d '' input_pdf; do
    found_input=true
    base_name="$(basename "$input_pdf")"
    base_name="${base_name%.*}"
    x1a_pdf="11-output/${base_name}.pdf"

    if [[ -e "$x1a_pdf" ]]; then
      echo "==> Skipping ${input_pdf}: output already exists at ${x1a_pdf}"
      continue
    fi

    convert "$input_pdf"
  done < <(find 00-input -maxdepth 1 -type f -iname '*.pdf' -print0 | sort -z)

  if [[ "$found_input" == "false" ]]; then
    echo "No PDF files found in 00-input/."
  fi
  exit 0
fi

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

convert "$input_pdf" "$start_step"
