#!/usr/bin/env bash
set -euo pipefail

usage() {
  echo "Usage: $0 <input-pdf>" >&2
  echo "       $0 --all" >&2
  echo "  --all: remove converted artifacts for every PDF in 00-input/" >&2
}

remove_converted() {
  local input_pdf="$1"
  local base_name
  local pattern
  local targets
  local matches
  local to_remove

  base_name="$(basename "$input_pdf")"
  base_name="${base_name%.*}"

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
    return
  fi

  printf 'Removing %s\n' "${to_remove[@]}"
  rm -rf -- "${to_remove[@]}"
}

if [[ $# -eq 1 && "$1" == "--all" ]]; then
  found_input=false
  while IFS= read -r -d '' input_pdf; do
    found_input=true
    remove_converted "$input_pdf"
  done < <(find 00-input -maxdepth 1 -type f -iname '*.pdf' -print0 | sort -z)

  if [[ "$found_input" == "false" ]]; then
    echo "No PDF files found in 00-input/."
  fi
  exit 0
fi

if [[ $# -ne 1 ]]; then
  usage
  exit 2
fi

input_pdf="$1"
if [[ ! -f "$input_pdf" ]]; then
  echo "ERROR: input file not found: $input_pdf" >&2
  exit 1
fi

if [[ "$input_pdf" != 00-input/* ]]; then
  echo "ERROR: input must be under 00-input/" >&2
  exit 1
fi

remove_converted "$input_pdf"
