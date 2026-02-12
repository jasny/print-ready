#!/usr/bin/env bash
set -euo pipefail

usage() {
  echo "Usage: $0 <03-extract-images/<doc>/obj-*-*.png> [barcode-data]" >&2
  echo "Or set BARCODE_DATA in the environment." >&2
}

if [[ $# -lt 1 || $# -gt 2 ]]; then
  usage
  exit 2
fi

src_img="$1"
if [[ ! -f "$src_img" ]]; then
  echo "ERROR: input file not found: $src_img" >&2
  exit 1
fi

if ! command -v zint >/dev/null 2>&1; then
  echo "ERROR: zint not found. Run ./00-install.sh first." >&2
  exit 1
fi

barcode_data="${2:-${BARCODE_DATA:-}}"
if [[ -z "$barcode_data" ]]; then
  echo "ERROR: barcode data is required (arg2 or BARCODE_DATA)." >&2
  exit 1
fi

barcode_type="${BARCODE_TYPE:-13}" # 13 = EAN-13 in zint
out_name="$(basename "$src_img")"
if [[ ! "$out_name" =~ ^obj-[0-9]+-[0-9]+\.png$ ]]; then
  echo "ERROR: expected filename like obj-<id>-<gen>.png, got: $out_name" >&2
  exit 1
fi
out_name="${out_name%.png}.up.eps"

doc_dir="$(basename "$(dirname "$src_img")")"
out_dir="06-resize-images/${doc_dir}"
mkdir -p "$out_dir"
out_eps="${out_dir}/${out_name}"

zint \
  --barcode="$barcode_type" \
  --data="$barcode_data" \
  --filetype=EPS \
  --output="$out_eps" \
  --notext

echo "Wrote $out_eps"
