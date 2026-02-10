#!/usr/bin/env bash
set -euo pipefail
export LC_ALL=C

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
output_low="${output_dir}/${base_name}.lowdpi.images.csv"

mkdir -p "$output_dir"

target_dpi="${TARGET_DPI:-300}"

tmp_csv="$(mktemp)"
tmp_low="$(mktemp)"

printf 'page,image_key,object,id,x_ppi,y_ppi,min_ppi,width,height,color,enc,type,low_dpi\n' > "$tmp_csv"
printf 'page,image_key,object,id,x_ppi,y_ppi,min_ppi,width,height,color,enc,type,low_dpi\n' > "$tmp_low"

pdfimages -list "$input_pdf" | awk -v target="$target_dpi" '
  NR <= 2 { next }
  {
    page=$1
    type=$3
    width=$4
    height=$5
    color=$6
    enc=$9
    object=$11
    id=$12
    x=$13
    y=$14
    if (x == "" || y == "" || object == "" || id == "") next
    min_ppi = (x+0 < y+0) ? x+0 : y+0
    low = ((x+0 < target || y+0 < target) ? 1 : 0)
    key = "obj-" object "-" id
    printf "%d,%s,%s,%s,%.2f,%.2f,%.2f,%s,%s,%s,%s,%s,%d\n", page, key, object, id, x+0, y+0, min_ppi, width, height, color, enc, type, low >> csv
    if (low == 1) {
      printf "%d,%s,%s,%s,%.2f,%.2f,%.2f,%s,%s,%s,%s,%s,%d\n", page, key, object, id, x+0, y+0, min_ppi, width, height, color, enc, type, low >> lowcsv
    }
  }
' csv="$tmp_csv" lowcsv="$tmp_low"

mv "$tmp_csv" "$output_csv"
mv "$tmp_low" "$output_low"

printf 'Wrote %s\n' "$output_csv"
printf 'Wrote %s\n' "$output_low"
