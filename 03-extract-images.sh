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

low_csv="02-analyze-dpi/${base_name}.lowdpi.images.csv"
if [[ ! -f "$low_csv" ]]; then
  echo "ERROR: missing low-DPI image list: $low_csv" >&2
  exit 1
fi

output_dir="03-extract-images/${base_name}"
mkdir -p "$output_dir"

# Build a set of low-DPI image keys (object + id)
low_keys="$(mktemp)"
awk -F, 'NR==1 {next} {print $3"-"$4}' "$low_csv" | sort -u > "$low_keys"

pdfimages -list "$input_pdf" | awk '
  NR<=2 {next}
  {
    page=$1
    num=$2
    type=$3
    width=$4
    height=$5
    color=$6
    enc=$9
    object=$11
    id=$12
    if (object == "" || id == "") next
    printf "%d,%d,%s,%s,%s,%s,%s,%s,%s\n", page, num, object, id, width, height, color, enc, type
  }
' | sort -t, -k2,2n > /tmp/pdfimages.list

all_tmpdir="$(mktemp -d)"
pdfimages -png "$input_pdf" "$all_tmpdir/img" >/dev/null

while IFS=, read -r page num object id width height color enc type; do
  key="${object}-${id}"
  if [[ "$type" == "smask" ]]; then
    continue
  fi
  if ! rg -q "^${key}$" "$low_keys"; then
    continue
  fi
  file_num=$(printf '%03d' "$num")
  src_file="${all_tmpdir}/img-${file_num}.png"
  if [[ ! -f "$src_file" ]]; then
    echo "ERROR: missing extracted file for image num $num (page $page)" >&2
    exit 1
  fi
  out_file="${output_dir}/obj-${object}-${id}.png"
  cp "$src_file" "$out_file"
  printf 'Wrote %s\n' "$out_file"
done < /tmp/pdfimages.list

rm -rf "$all_tmpdir"
rm -f "$low_keys" /tmp/pdfimages.list
