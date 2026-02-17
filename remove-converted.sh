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

base_name="$(basename "$input_pdf")"
base_name="${base_name%.*}"

if [[ "$input_pdf" != 00-input/* ]]; then
  echo "ERROR: input must be under 00-input/" >&2
  exit 1
fi

targets=(
  "01-validate/${base_name}."*
  "02-analyze-dpi/${base_name}."*
  "03-extract-images/${base_name}"
  "04-upscale-images/${base_name}"
  "05-verify-images/${base_name}"
  "06-resize-images/${base_name}"
  "07-resize-smasks/${base_name}"
  "08-replace-images/${base_name}."*
  "09-normalize-pdf/${base_name}."*
  "10-pdf-x4/${base_name}."*
  "11-output/${base_name}."*
)

shopt -s nullglob
to_remove=()
for pattern in "${targets[@]}"; do
  matches=( $pattern )
  if [[ ${#matches[@]} -gt 0 ]]; then
    to_remove+=("${matches[@]}")
  fi
done
shopt -u nullglob

if [[ ${#to_remove[@]} -eq 0 ]]; then
  echo "Nothing to remove for ${base_name}."
  exit 0
fi

printf 'Removing %s\n' "${to_remove[@]}"
rm -rf -- "${to_remove[@]}"
