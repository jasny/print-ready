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
output_dir="01-validate"
output_file="${output_dir}/${base_name}.validated.txt"

mkdir -p "$output_dir"

tmp_report="$(mktemp)"
fail_reason=""

pdfinfo_out="$(pdfinfo "$input_pdf")"

pages="$(echo "$pdfinfo_out" | awk -F: '/^Pages:/ {gsub(/^[ \t]+/,"",$2); print $2}')"
if [[ -z "$pages" || "$pages" -le 0 ]]; then
  fail_reason="page count is zero"
fi

encrypted="$(echo "$pdfinfo_out" | awk -F: '/^Encrypted:/ {gsub(/^[ \t]+/,"",$2); print $2}')"
if [[ -z "$fail_reason" && "$encrypted" != "no" ]]; then
  fail_reason="PDF is encrypted"
fi

# Page size consistency check (per-page)
size_list=()
if [[ -z "$fail_reason" ]]; then
  for ((i=1; i<=pages; i++)); do
    size_line="$(pdfinfo -f "$i" -l "$i" -box "$input_pdf" | awk -v p="$i" '$1=="Page" && $2==p && $3=="size:" {print $4" x "$6" pts"; exit}')"
    if [[ -z "$size_line" ]]; then
      fail_reason="failed to read page size for page $i"
      break
    fi
    size_list+=("$size_line")
  done
fi

unique_sizes="$(printf '%s\n' "${size_list[@]}" | sort -u)"
if [[ -z "$fail_reason" ]]; then
  unique_count="$(printf '%s\n' "$unique_sizes" | grep -c . || true)"
  if [[ "$unique_count" -ne 1 ]]; then
    fail_reason="page sizes differ"
  fi
fi

# Basic color space detection based on embedded images
colors="$(pdfimages -list "$input_pdf" | awk 'NR>2 {print $6}' | sort -u | tr '\n' ' ' | sed 's/[[:space:]]\+$//')"
if [[ -z "$colors" ]]; then
  colors="(no embedded images detected)"
fi

sha256="$(sha256sum "$input_pdf" | awk '{print $1}')"

{
  echo "Input: $input_pdf"
  echo "Pages: ${pages:-unknown}"
  if [[ -n "$unique_sizes" ]]; then
    echo "Page size: $unique_sizes"
  else
    echo "Page size: (unknown)"
  fi
  echo "Encrypted: ${encrypted:-unknown}"
  echo "Image color spaces: $colors"
  echo "SHA256: $sha256"
  if [[ -z "$fail_reason" ]]; then
    echo "Status: OK"
  else
    echo "Status: FAIL"
    echo "Reason: $fail_reason"
  fi
} > "$tmp_report"

mv "$tmp_report" "$output_file"

if [[ -n "$fail_reason" ]]; then
  echo "Validation failed: $fail_reason" >&2
  exit 1
fi

printf 'Wrote %s\n' "$output_file"
