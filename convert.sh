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
  "./10-set-trim.sh"
  "./11-pdf-x1a.sh"
)

for step in "${steps[@]}"; do
  echo "==> Running ${step} ${input_pdf}"
  "${step}" "${input_pdf}"
done

base_name="$(basename "$input_pdf")"
base_name="${base_name%.*}"
x4_pdf="10-pdf-x4/${base_name}.print.pdf"
x1a_pdf="11-output/${base_name}.print.x1a.pdf"

echo "==> Running ./preflight.sh ${x4_pdf}"
./preflight.sh "${x4_pdf}"
echo "==> Running ./preflight.sh ${x1a_pdf}"
./preflight.sh "${x1a_pdf}"
