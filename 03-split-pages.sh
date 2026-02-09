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
output_dir="03-split-pages/${base_name}"

mkdir -p "$output_dir"

pages="$(pdfinfo "$input_pdf" | awk -F: '/^Pages:/ {gsub(/^[ \t]+/,"",$2); print $2}')"
if [[ -z "$pages" || "$pages" -le 0 ]]; then
  echo "ERROR: failed to read page count" >&2
  exit 1
fi

for ((i=1; i<=pages; i++)); do
  page_num=$(printf '%03d' "$i")
  out_file="${output_dir}/p${page_num}.pdf"
  qpdf "$input_pdf" --pages "$input_pdf" "$i" -- "$out_file"
  if [[ ! -s "$out_file" ]]; then
    echo "ERROR: failed to write $out_file" >&2
    exit 1
  fi
  page_size="$(pdfinfo -f "$i" -l "$i" -box "$input_pdf" | awk -v p="$i" '$1=="Page" && $2==p && $3=="size:" {print $4" x "$6" pts"; exit}')"
  split_size="$(pdfinfo -box "$out_file" | awk '$1=="Page" && $2=="size:" {print $3" x "$5" pts"; exit}')"
  if [[ -n "$page_size" && -n "$split_size" && "$page_size" != "$split_size" ]]; then
    echo "ERROR: page size mismatch on page $i ($page_size vs $split_size)" >&2
    exit 1
  fi
  
  printf 'Wrote %s\n' "$out_file"
done
