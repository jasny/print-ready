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

if [[ "${FORCE_CPU:-}" != "1" ]]; then
  if ! command -v nvidia-smi >/dev/null 2>&1; then
    echo "ERROR: GPU required for Real-ESRGAN. Connect GPU or set FORCE_CPU=1 to attempt CPU (not recommended)." >&2
    exit 1
  fi
  if ! nvidia-smi -L >/dev/null 2>&1; then
    echo "ERROR: No NVIDIA GPU detected. Connect GPU or set FORCE_CPU=1 to attempt CPU (not recommended)." >&2
    exit 1
  fi
fi

if ! command -v realesrgan-ncnn-vulkan >/dev/null 2>&1; then
  echo "ERROR: realesrgan-ncnn-vulkan not found in PATH" >&2
  exit 1
fi

base_name="$(basename "$input_pdf")"
base_name="${base_name%.*}"

lowdpi_file="02-analyze-dpi/${base_name}.lowdpi.pages.txt"
dpi_csv="02-analyze-dpi/${base_name}.dpi.csv"
input_dir="04-rasterize-lowdpi/${base_name}"
output_dir="05-upscale/${base_name}"
report_csv="05-upscale/${base_name}.upscale.csv"

mkdir -p "$output_dir"

if [[ ! -f "$lowdpi_file" || ! -f "$dpi_csv" ]]; then
  echo "ERROR: missing DPI inputs for $base_name" >&2
  exit 1
fi

if [[ ! -s "$lowdpi_file" ]]; then
  printf 'page,min_ppi,scale_required,esrgan_scale,final_scale,model,gpu_id\n' > "$report_csv"
  printf 'Wrote %s\n' "$report_csv"
  exit 0
fi

target_dpi="${TARGET_DPI:-300}"
max_upscale="${MAX_UPSCALE:-4.0}"
model_name="${UPSCALER_MODEL:-realesrgan-x4plus}"
extra_args="${REAL_ESRGAN_ARGS:-}"

gpu_id="${GPU_ID:-}"
if [[ -z "${gpu_id}" && "${FORCE_CPU:-}" != "1" ]]; then
  echo "ERROR: GPU_ID is required (set to the NVIDIA device index, e.g., GPU_ID=1)." >&2
  exit 1
fi

if [[ "${FORCE_CPU:-}" == "1" ]]; then
  echo "FORCE_CPU=1 set. Skipping NVIDIA check; Real-ESRGAN will use Vulkan device ${gpu_id} (may be llvmpipe)." >&2
fi

printf 'page,min_ppi,scale_required,esrgan_scale,final_scale,model,gpu_id\n' > "$report_csv"

while read -r page; do
  [[ -z "$page" ]] && continue
  page="${page//$'\r'/}"
  page_num=$(printf '%03d' "$page")
  raw_file="${input_dir}/p${page_num}.raw.png"
  if [[ ! -f "$raw_file" ]]; then
    echo "ERROR: missing rasterized page: $raw_file" >&2
    exit 1
  fi

  min_ppi=$(awk -F, -v p="$page" '$1==p {print $4; exit}' "$dpi_csv")
  if [[ -z "$min_ppi" ]]; then
    echo "ERROR: missing min_ppi for page $page" >&2
    exit 1
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

  tmp_out="${output_dir}/p${page_num}.esrgan.png"
  final_out="${output_dir}/p${page_num}.up.png"

  echo "Upscaling: $raw_file -> $final_out (scale $esrgan_scale, gpu $gpu_id)" >&2
  tmp_err="$(mktemp)"
  realesrgan-ncnn-vulkan -i "$raw_file" -o "$tmp_out" -s "$esrgan_scale" -n "$model_name" -g "$gpu_id" -f png $extra_args 2> "$tmp_err"

  if [[ ! -s "$tmp_out" ]]; then
    echo "ERROR: Real-ESRGAN failed for page $page" >&2
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

  printf '%s,%s,%s,%s,%s,%s,%s\n' "$page" "$min_ppi" "$scale_required" "$esrgan_scale" "$final_scale" "$model_name" "$gpu_id" >> "$report_csv"
  printf 'Wrote %s\n' "$final_out"
done < "$lowdpi_file"

printf 'Wrote %s\n' "$report_csv"
