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
up_dir="04-upscale-images/${base_name}"
output_dir="05-verify-images/${base_name}"
report_csv="05-verify-images/${base_name}.verify.csv"

mkdir -p "$output_dir"

if [[ ! -f "$low_csv" ]]; then
  echo "ERROR: missing low-DPI image list: $low_csv" >&2
  exit 1
fi

if [[ ! -d "$up_dir" ]]; then
  echo "ERROR: missing upscaled images directory: $up_dir" >&2
  exit 1
fi

target_dpi="${TARGET_DPI:-300}"

printf 'image_key,orig_w,orig_h,new_w,new_h,min_ppi,new_min_ppi,meets_target\n' > "$report_csv"

while IFS=, read -r page image_key object id x_ppi y_ppi min_ppi width height color enc type low_dpi; do
  if [[ "$image_key" == "image_key" || -z "$image_key" ]]; then
    continue
  fi

  src_file="${up_dir}/${image_key}.up.png"
  if [[ ! -f "$src_file" ]]; then
    continue
  fi

  dims="$(identify -format '%w %h' "$src_file" 2>/dev/null || true)"
  if [[ -z "$dims" ]]; then
    echo "ERROR: failed to read dimensions for $src_file" >&2
    exit 1
  fi
  read -r new_w new_h <<< "$dims"

  scale_w=$(awk -v nw="$new_w" -v ow="$width" 'BEGIN {if (ow==0) {print 0} else {printf "%.6f", nw/ow}}')
  new_min_ppi=$(awk -v m="$min_ppi" -v s="$scale_w" 'BEGIN {printf "%.2f", m*s}')

  meets=1
  if awk -v p="$new_min_ppi" -v t="$target_dpi" 'BEGIN {exit !(p<t)}'; then
    meets=0
  fi

  printf '%s,%s,%s,%s,%s,%.2f,%.2f,%d\n' "$image_key" "$width" "$height" "$new_w" "$new_h" "$min_ppi" "$new_min_ppi" "$meets" >> "$report_csv"

  if [[ "$meets" -eq 0 ]]; then
    cp "$src_file" "$output_dir/"
  fi

done < "$low_csv"

printf 'Wrote %s\n' "$report_csv"
