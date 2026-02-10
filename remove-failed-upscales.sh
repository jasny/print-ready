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

failed_dir="05-verify-images/${base_name}"
up_dir="04-upscale-images/${base_name}"

if [[ ! -d "$failed_dir" ]]; then
  echo "ERROR: missing failed images directory: $failed_dir" >&2
  exit 1
fi

if [[ ! -d "$up_dir" ]]; then
  echo "ERROR: missing upscaled images directory: $up_dir" >&2
  exit 1
fi

shopt -s nullglob
for f in "$failed_dir"/*.png; do
  name="$(basename "$f")"
  if [[ -f "$up_dir/$name" ]]; then
    rm -f "$up_dir/$name"
    echo "Removed $up_dir/$name"
  fi
done
