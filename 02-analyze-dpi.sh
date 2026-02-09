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
output_dir="02-analyze-dpi"
output_csv="${output_dir}/${base_name}.dpi.csv"
output_low="${output_dir}/${base_name}.lowdpi.pages.txt"

mkdir -p "$output_dir"

target_dpi="${TARGET_DPI:-300}"

pages="$(pdfinfo "$input_pdf" | awk -F: '/^Pages:/ {gsub(/^[ \t]+/,"",$2); print $2}')"
if [[ -z "$pages" || "$pages" -le 0 ]]; then
  echo "ERROR: failed to read page count" >&2
  exit 1
fi

tmp_csv="$(mktemp)"
tmp_low="$(mktemp)"

pdfimages -list "$input_pdf" | awk -v pages="$pages" -v target="$target_dpi" '
  NR <= 2 { next }
  {
    p=$1
    x=$13
    y=$14
    if (x == "" || y == "") next
    if (!(p in minx) || x+0 < minx[p]) minx[p]=x+0
    if (!(p in miny) || y+0 < miny[p]) miny[p]=y+0
    count[p]++
    if (x+0 < target || y+0 < target) lowdpi[p]=1
  }
  END {
    print "page,min_x_ppi,min_y_ppi,min_ppi,low_dpi" > csv
    for (i=1; i<=pages; i++) {
      if (count[i] > 0) {
        min_ppi = (minx[i] < miny[i]) ? minx[i] : miny[i]
        low_flag = (lowdpi[i] ? 1 : 0)
        printf "%d,%.2f,%.2f,%.2f,%d\n", i, minx[i], miny[i], min_ppi, low_flag >> csv
        if (low_flag == 1) {
          print i >> lowfile
        }
      } else {
        printf "%d,,,,0\n", i >> csv
      }
    }
  }
' csv="$tmp_csv" lowfile="$tmp_low"

mv "$tmp_csv" "$output_csv"
mv "$tmp_low" "$output_low"

printf 'Wrote %s\n' "$output_csv"
printf 'Wrote %s\n' "$output_low"
