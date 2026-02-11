#!/usr/bin/env bash
set -euo pipefail
export LC_ALL=C

usage() {
  echo "Usage: $0 <image-from-03-extract-images>" >&2
}

if [[ $# -ne 1 ]]; then
  usage
  exit 2
fi

src_image="$1"
if [[ ! -f "$src_image" ]]; then
  echo "ERROR: input image not found: $src_image" >&2
  exit 1
fi

if [[ "$src_image" != 03-extract-images/*/*.png ]]; then
  echo "ERROR: input must be under 03-extract-images/<doc>/*.png" >&2
  exit 1
fi

doc_name="$(basename "$(dirname "$src_image")")"
image_file="$(basename "$src_image")"
image_key="${image_file%.png}"

low_csv="02-analyze-dpi/${doc_name}.lowdpi.images.csv"
dpi_csv="02-analyze-dpi/${doc_name}.dpi.csv"
if [[ ! -f "$low_csv" && ! -f "$dpi_csv" ]]; then
  echo "ERROR: missing DPI csv for ${doc_name}" >&2
  exit 1
fi

csv_file="$low_csv"
if [[ ! -f "$csv_file" ]]; then
  csv_file="$dpi_csv"
fi

row="$(awk -F, -v k="$image_key" 'NR>1 && $2==k {print; exit}' "$csv_file")"
if [[ -z "$row" ]]; then
  if [[ "$csv_file" != "$dpi_csv" && -f "$dpi_csv" ]]; then
    row="$(awk -F, -v k="$image_key" 'NR>1 && $2==k {print; exit}' "$dpi_csv")"
  fi
fi
if [[ -z "$row" ]]; then
  echo "ERROR: image key not found in DPI CSV: $image_key" >&2
  exit 1
fi

IFS=, read -r _page _image_key _object _id _x_ppi _y_ppi min_ppi _width _height _color _enc _type _low_dpi <<< "$row"
if [[ -z "$min_ppi" ]]; then
  echo "ERROR: min_ppi missing for $image_key" >&2
  exit 1
fi

target_dpi="${TARGET_DPI:-300}"
dpi_margin="${DPI_MARGIN:-3}"
max_upscale="${MAX_UPSCALE:-4.0}"
target_dpi_eff="$(awk -v t="$target_dpi" -v m="$dpi_margin" 'BEGIN {printf "%.6f", t+m}')"
scale_required="$(awk -v t="$target_dpi_eff" -v m="$min_ppi" -v mx="$max_upscale" 'BEGIN {s=t/m; if (s<1) s=1; if (s>mx) s=mx; printf "%.6f", s}')"
downscale_percent="$(awk -v s="$scale_required" 'BEGIN {printf "%.2f", (s/4.0)*100}')"

out_dir="04-upscale-images/${doc_name}"
mkdir -p "$out_dir"
out_file="${out_dir}/${image_key}.up.png"
tmp_file="${out_dir}/${image_key}.esrgan4.png"

model_name="${UPSCALER_MODEL_NCNN:-realesrgan-x4plus}"
gpu_id="${GPU_ID:-}"
force_cpu="${FORCE_CPU:-0}"

cmd=(realesrgan-ncnn-vulkan -i "$src_image" -o "$tmp_file" -n "$model_name" -f png)
if [[ "$force_cpu" == "1" ]]; then
  cmd+=(-g -1)
elif [[ -n "$gpu_id" ]]; then
  cmd+=(-g "$gpu_id")
fi

echo "Image: $src_image"
echo "min_ppi=${min_ppi} target_dpi=${target_dpi} dpi_margin=${dpi_margin} scale_required=${scale_required}"
echo "Running: ${cmd[*]}"
"${cmd[@]}"

echo "Downscaling ESRGAN x4 output to ${downscale_percent}%"
convert "$tmp_file" -filter Lanczos -resize "${downscale_percent}%" "$out_file"
rm -f "$tmp_file"

rm -f "05-verify-images/${doc_name}/${image_key}.up.png"
rm -f "06-resize-images/${doc_name}/${image_key}.up.png"

echo "Wrote: $out_file"
echo "Removed (if present): 05-verify-images/${doc_name}/${image_key}.up.png"
echo "Removed (if present): 06-resize-images/${doc_name}/${image_key}.up.png"
