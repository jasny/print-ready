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
failed_dir="05-verify-images/${base_name}"
output_dir="06-resize-images/${base_name}"

mkdir -p "$output_dir"

if [[ ! -f "$low_csv" ]]; then
  echo "ERROR: missing low-DPI image list: $low_csv" >&2
  exit 1
fi

if [[ ! -d "$failed_dir" ]]; then
  echo "ERROR: missing failed images directory: $failed_dir" >&2
  exit 1
fi

target_dpi="${TARGET_DPI:-300}"

while IFS=, read -r page image_key object id x_ppi y_ppi min_ppi width height color enc type low_dpi; do
  if [[ "$image_key" == "image_key" || -z "$image_key" ]]; then
    continue
  fi

  src_file="${failed_dir}/${image_key}.up.png"
  if [[ ! -f "$src_file" ]]; then
    continue
  fi

  dims="$(identify -format '%w %h' "$src_file" 2>/dev/null || true)"
  if [[ -z "$dims" ]]; then
    echo "ERROR: failed to read dimensions for $src_file" >&2
    exit 1
  fi
  read -r new_w new_h <<< "$dims"

  if [[ "$width" -eq 0 ]]; then
    echo "ERROR: original width is zero for $image_key" >&2
    exit 1
  fi

  scale_total=$(awk -v t="$target_dpi" -v m="$min_ppi" 'BEGIN {printf "%.6f", t/m}')
  current_scale=$(awk -v nw="$new_w" -v ow="$width" 'BEGIN {printf "%.6f", nw/ow}')
  extra_scale=$(awk -v s="$scale_total" -v c="$current_scale" 'BEGIN {printf "%.6f", s/c}')

  if awk -v s="$extra_scale" 'BEGIN {exit !(s<=1)}'; then
    cp "$src_file" "$output_dir/"
    continue
  fi

  percent=$(awk -v s="$extra_scale" 'BEGIN {printf "%.2f", s*100}')
  out_file="${output_dir}/${image_key}.up.png"
  convert "$src_file" -resize "${percent}%" "$out_file"
  echo "Resized $image_key by ${percent}%"

done < "$low_csv"
