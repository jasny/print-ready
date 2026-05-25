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
poppler_suspects_warning="Syntax Error: Suspects object is wrong type (boolean)"

pdfinfo_filtered() {
  pdfinfo "$@" 2> >(grep -Fv "$poppler_suspects_warning" >&2)
}

pdfinfo_out="$(pdfinfo_filtered "$input_pdf")"

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
  box_info="$(pdfinfo_filtered -f 1 -l "$pages" -box "$input_pdf")"
  mapfile -t size_list < <(awk '$1=="Page" && $3=="size:" {print $4" x "$6" pts"}' <<< "$box_info")
  if [[ "${#size_list[@]}" -ne "$pages" ]]; then
    fail_reason="failed to read page size for all pages"
  fi
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
