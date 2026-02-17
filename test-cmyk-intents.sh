#!/usr/bin/env bash
set -euo pipefail

usage() {
  cat >&2 <<'EOF'
Usage: ./test-cmyk-intents.sh <image-file>

Env vars:
  COLOR_PROFILE   Destination CMYK ICC profile.
                  Default: /usr/share/color/icc/colord/FOGRA29L_uncoated.icc
  SOURCE_PROFILE  Source RGB ICC profile (optional auto-detect fallback).
EOF
}

if [[ $# -ne 1 ]]; then
  usage
  exit 2
fi

input_image="$1"
if [[ ! -f "$input_image" ]]; then
  echo "ERROR: input image not found: $input_image" >&2
  exit 1
fi

dest_profile="${COLOR_PROFILE:-/usr/share/color/icc/colord/FOGRA29L_uncoated.icc}"
if [[ ! -f "$dest_profile" ]]; then
  echo "ERROR: destination ICC profile not found: $dest_profile" >&2
  exit 1
fi

source_profile="${SOURCE_PROFILE:-}"
if [[ -z "$source_profile" ]]; then
  for candidate in \
    /usr/share/color/icc/colord/sRGB.icc \
    /usr/share/color/icc/sRGB.icc \
    /usr/share/color/icc/ghostscript/srgb.icc
  do
    if [[ -f "$candidate" ]]; then
      source_profile="$candidate"
      break
    fi
  done
fi

if [[ -z "$source_profile" || ! -f "$source_profile" ]]; then
  echo "ERROR: SOURCE_PROFILE not set and no system sRGB profile found." >&2
  echo "Set SOURCE_PROFILE=/path/to/sRGB.icc and retry." >&2
  exit 1
fi

in_dir="$(dirname "$input_image")"
in_file="$(basename "$input_image")"
base="${in_file%.*}"
out_dir="${in_dir}/${base}.intents"
mkdir -p "$out_dir"

intents=(perceptual relative saturation absolute)

echo "Input: $input_image"
echo "Source profile: $source_profile"
echo "Destination profile: $dest_profile"
echo "Output dir: $out_dir"

for intent in "${intents[@]}"; do
  cmyk_out="${out_dir}/${base}.${intent}.cmyk.tif"
  proof_out="${out_dir}/${base}.${intent}.proof.png"

  echo "Converting intent=${intent}"
  convert "$input_image" \
    -profile "$source_profile" \
    -intent "$intent" \
    -black-point-compensation \
    -profile "$dest_profile" \
    "$cmyk_out"

  convert "$cmyk_out" \
    -profile "$dest_profile" \
    -profile "$source_profile" \
    "$proof_out"
done

echo "Wrote intent variants to $out_dir"
