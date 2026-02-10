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

lowdpi_file="02-analyze-dpi/${base_name}.lowdpi.pages.txt"
if [[ ! -f "$lowdpi_file" ]]; then
  echo "ERROR: missing low-DPI list: $lowdpi_file" >&2
  exit 1
fi

output_dir="04-rasterize-lowdpi/${base_name}"
report_file="04-rasterize-lowdpi/${base_name}.rasterize.txt"
mkdir -p "$output_dir"

rasterize_dpi="${RASTERIZE_DPI:-400}"
image_format="${IMAGE_FORMAT:-png}"

{
  echo "Input: $input_pdf"
  echo "Low-DPI list: $lowdpi_file"
  echo "Rasterize DPI: $rasterize_dpi"
  echo "Image format: $image_format"
  echo "Started: $(date -u +%Y-%m-%dT%H:%M:%SZ)"
} > "$report_file"

if [[ ! -s "$lowdpi_file" ]]; then
  echo "No low-DPI pages. Skipping rasterization." >> "$report_file"
  printf 'Wrote %s\n' "$report_file"
  exit 0
fi

while read -r page; do
  [[ -z "$page" ]] && continue
  page_num=$(printf '%03d' "$page")
  src_page="03-split-pages/${base_name}/p${page_num}.pdf"
  if [[ ! -f "$src_page" ]]; then
    echo "ERROR: missing source page: $src_page" >&2
    exit 1
  fi
  out_base="${output_dir}/p${page_num}.raw"
  pdftoppm -r "$rasterize_dpi" -"$image_format" -singlefile "$src_page" "$out_base"
  out_file="${out_base}.${image_format}"
  if [[ ! -s "$out_file" ]]; then
    echo "ERROR: failed to rasterize page $page" >&2
    exit 1
  fi
  echo "Rasterized page $page -> $out_file" >> "$report_file"
  printf 'Wrote %s\n' "$out_file"
done < "$lowdpi_file"

printf 'Wrote %s\n' "$report_file"
