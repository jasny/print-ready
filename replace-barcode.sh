#!/usr/bin/env bash
set -euo pipefail

usage() {
  echo "Usage: $0 <03-extract-images/<doc>/obj-*-*.png> [barcode-data]" >&2
  echo "If barcode-data is omitted, script tries to decode via ZXingReader." >&2
  echo "Or set BARCODE_DATA in the environment." >&2
  echo "Deep black color can be overridden with DEEP_BLACK_CMYK (default: 0.5 0.4 0.4 1)." >&2
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
  if ! command -v ZXingReader >/dev/null 2>&1; then
    echo "ERROR: barcode data not provided and ZXingReader not found." >&2
    echo "Install zxing-cpp-tools or pass barcode data as arg2." >&2
    exit 1
  fi
  # ZXingReader output varies by version; accept both "Text: <value>" and plain value.
  decoded="$(
    ZXingReader "$src_img" 2>/dev/null \
      | awk -F': ' '/^Text: / {print $2; found=1} END {if (!found && NR==1) print $0}'
  )"
  barcode_data="$(echo "$decoded" | tr -d '\r' | sed -e 's/^[[:space:]]*//' -e 's/[[:space:]]*$//' -e 's/^\"//' -e 's/\"$//')"
  if [[ -z "$barcode_data" ]]; then
    echo "ERROR: could not decode barcode from: $src_img" >&2
    echo "Provide barcode data as arg2 or BARCODE_DATA." >&2
    exit 1
  fi
  echo "Decoded barcode data: $barcode_data"
fi

barcode_type="${BARCODE_TYPE:-13}" # 13 = EAN-13 in zint
deep_black_cmyk="${DEEP_BLACK_CMYK:-0.5 0.4 0.4 1}"
paper_white_cmyk="${PAPER_WHITE_CMYK:-0 0 0 0}"
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

# Force CMYK color operators in generated EPS.
tmp_eps="$(mktemp)"
awk -v deep="$deep_black_cmyk" -v white="$paper_white_cmyk" '
  /^[[:space:]]*1[[:space:]]+1[[:space:]]+1[[:space:]]+setrgbcolor[[:space:]]*$/ {
    print white " setcmykcolor"
    next
  }
  /^[[:space:]]*0[[:space:]]+0[[:space:]]+0[[:space:]]+setrgbcolor[[:space:]]*$/ {
    print deep " setcmykcolor"
    next
  }
  { print }
' "$out_eps" > "$tmp_eps"
mv "$tmp_eps" "$out_eps"

echo "Wrote $out_eps"
