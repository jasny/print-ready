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

if ! command -v realesrgan-ncnn-vulkan >/dev/null 2>&1; then
  echo "ERROR: realesrgan-ncnn-vulkan not found in PATH" >&2
  exit 1
fi

base_name="$(basename "$input_pdf")"
base_name="${base_name%.*}"

low_csv="02-analyze-dpi/${base_name}.lowdpi.images.csv"
input_dir="03-extract-images/${base_name}"
output_dir="04-upscale-images/${base_name}"

mkdir -p "$output_dir"

if [[ ! -f "$low_csv" ]]; then
  echo "ERROR: missing low-DPI image list: $low_csv" >&2
  exit 1
fi

if [[ ! -d "$input_dir" ]]; then
  echo "ERROR: missing extracted images directory: $input_dir" >&2
  exit 1
fi

gpu_id=""
if [[ "${FORCE_CPU:-}" != "1" ]]; then
  if [[ -n "${GPU_ID:-}" ]]; then
    gpu_id="${GPU_ID}"
  else
    if command -v vulkaninfo >/dev/null 2>&1; then
      gpu_map="$(vulkaninfo --summary 2>/dev/null | awk '
        function emit() {
          if (id != "" && type != "PHYSICAL_DEVICE_TYPE_CPU") {
            label = (name != "" ? name : (vendor != "" ? vendor : "Unknown GPU"))
            print "GPU" id ": " label
          }
        }
        /^GPU[0-9]+:/ {
          emit()
          gsub(/GPU|:/, "", $1)
          id=$1; name=""; type=""; vendor=""
          next
        }
        /deviceName/ {sub(/.*= /, "", $0); name=$0}
        /deviceType/ {sub(/.*= /, "", $0); type=$0}
        /vendorID/ {sub(/.*= /, "", $0); vendor=$0}
        END { emit() }
      ')"
      gpu_count="$(printf '%s\n' "$gpu_map" | grep -c '^GPU' || true)"
      if [[ "$gpu_count" -eq 1 ]]; then
        gpu_id="$(printf '%s\n' "$gpu_map" | sed -E 's/^GPU([0-9]+):.*/\\1/')"
      else
        echo "Available GPUs:" >&2
        printf '%s\n' "$gpu_map" >&2
        echo "ERROR: GPU_ID is required when multiple GPUs are present." >&2
        exit 1
      fi
    else
      echo "ERROR: GPU_ID is required (set to the Vulkan device index, e.g., GPU_ID=1)." >&2
      exit 1
    fi
  fi
fi

target_dpi="${TARGET_DPI:-300}"
max_upscale="${MAX_UPSCALE:-4.0}"
model_name="${UPSCALER_MODEL:-realesrgan-x4plus}"
tile_size="${TILE_SIZE:-0}"
extra_args="${REAL_ESRGAN_ARGS:-}"

if [[ "${FORCE_CPU:-}" == "1" ]]; then
  echo "FORCE_CPU=1 set. Real-ESRGAN will use Vulkan device 0 (may be llvmpipe)." >&2
  gpu_id=0
fi

while IFS=, read -r page image_key object id x_ppi y_ppi min_ppi width height color enc type low_dpi; do
  if [[ "$image_key" == "image_key" || -z "$image_key" ]]; then
    continue
  fi
  src_file="${input_dir}/${image_key}.png"
  if [[ ! -f "$src_file" ]]; then
    continue
  fi
  final_out="${output_dir}/${image_key}.up.png"
  if [[ -s "$final_out" ]]; then
    continue
  fi

  scale_required=$(awk -v t="$target_dpi" -v m="$min_ppi" 'BEGIN {s=t/m; if (s<1) s=1; printf "%.4f", s}')
  scale_required=$(awk -v s="$scale_required" -v max="$max_upscale" 'BEGIN {if (s>max) s=max; printf "%.4f", s}')

  if awk -v s="$scale_required" 'BEGIN {exit !(s<=2)}'; then
    esrgan_scale=2
  elif awk -v s="$scale_required" 'BEGIN {exit !(s<=3)}'; then
    esrgan_scale=3
  else
    esrgan_scale=4
  fi

  tmp_out="${output_dir}/${image_key}.esrgan.png"

  echo "Upscaling: $src_file -> $final_out (scale $esrgan_scale, gpu $gpu_id)" >&2
  tmp_err="$(mktemp)"
  realesrgan-ncnn-vulkan -i "$src_file" -o "$tmp_out" -s "$esrgan_scale" -n "$model_name" -g "$gpu_id" -t "$tile_size" -f png $extra_args 2> "$tmp_err"

  if [[ ! -s "$tmp_out" ]]; then
    echo "ERROR: Real-ESRGAN failed for $image_key" >&2
    if [[ -s "$tmp_err" ]]; then
      echo "Real-ESRGAN stderr:" >&2
      cat "$tmp_err" >&2
    fi
    exit 1
  fi
  rm -f "$tmp_err"

  final_scale=$(awk -v req="$scale_required" -v es="$esrgan_scale" 'BEGIN {printf "%.4f", req/es}')
  if awk -v s="$final_scale" 'BEGIN {exit !(s==1)}'; then
    mv "$tmp_out" "$final_out"
  else
    percent=$(awk -v s="$final_scale" 'BEGIN {printf "%.2f", s*100}')
    convert "$tmp_out" -resize "${percent}%" "$final_out"
    rm -f "$tmp_out"
  fi

  if [[ ! -s "$final_out" ]]; then
    echo "ERROR: failed to write $final_out" >&2
    exit 1
  fi

done < "$low_csv"
