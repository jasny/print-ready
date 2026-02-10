#!/usr/bin/env bash
set -euo pipefail

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

steps=(
  "./01-validate.sh"
  "./02-analyze-dpi.sh"
  "./03-extract-images.sh"
  "./04-upscale-images.sh"
  "./05-verify-images.sh"
  "./06-resize-images.sh"
  "./07-resize-smasks.sh"
  "./08-replace-images.sh"
  "./09-normalize-pdf.sh"
  "./10-preflight.sh"
)

for step in "${steps[@]}"; do
  echo "==> Running ${step} ${input_pdf}"
  "${step}" "${input_pdf}"
done
