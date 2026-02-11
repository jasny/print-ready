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

src_pdf="09-normalize-pdf/${base_name}.print.pdf"
if [[ ! -f "$src_pdf" ]]; then
  src_pdf="$input_pdf"
fi

target_dpi="${TARGET_DPI:-300}"
min_dpi="$(awk -v t="$target_dpi" 'BEGIN { printf "%.2f", t * 0.95 }')"
pdf_standard="${PDF_STANDARD:-PDF/X-4}"
default_profile="profiles/PSO_Uncoated_ISO12647_eci.icc"
color_profile="${COLOR_PROFILE:-$default_profile}"

failures=()

orig_info="$(pdfinfo "$input_pdf")"
src_info="$(pdfinfo "$src_pdf")"

orig_pages="$(echo "$orig_info" | awk -F: '/^Pages:/ {gsub(/^[ \t]+/,"",$2); print $2}')"
src_pages="$(echo "$src_info" | awk -F: '/^Pages:/ {gsub(/^[ \t]+/,"",$2); print $2}')"

if [[ -z "$orig_pages" || "$orig_pages" -le 0 ]]; then
  failures+=("original page count is invalid")
fi
if [[ -z "$src_pages" || "$src_pages" -le 0 ]]; then
  failures+=("normalized page count is invalid")
fi
if [[ -n "$orig_pages" && -n "$src_pages" && "$orig_pages" -ne "$src_pages" ]]; then
  failures+=("page count differs between original and normalized")
fi

page_size_mismatch=""
if [[ "${#failures[@]}" -eq 0 ]]; then
  for ((i=1; i<=orig_pages; i++)); do
    orig_size="$(pdfinfo -f "$i" -l "$i" -box "$input_pdf" | awk -v p="$i" '$1=="Page" && $2==p && $3=="size:" {print $4" x "$6" pts"; exit}')"
    norm_size="$(pdfinfo -f "$i" -l "$i" -box "$src_pdf" | awk -v p="$i" '$1=="Page" && $2==p && $3=="size:" {print $4" x "$6" pts"; exit}')"
    if [[ -z "$orig_size" || -z "$norm_size" ]]; then
      page_size_mismatch="failed to read page size for page $i"
      break
    fi
    if [[ "$orig_size" != "$norm_size" ]]; then
      page_size_mismatch="page $i size differs (${orig_size} vs ${norm_size})"
      break
    fi
  done
fi
if [[ -n "$page_size_mismatch" ]]; then
  failures+=("$page_size_mismatch")
fi

page_size_mm="unknown"
if [[ -n "$orig_pages" && "$orig_pages" -gt 0 ]]; then
  page_size_mm="$(pdfinfo -f 1 -l 1 -box "$src_pdf" | awk '
    $1=="Page" && $2==1 && $3=="size:" {
      w_pt=$4+0; h_pt=$6+0;
      w_mm=w_pt*25.4/72.0;
      h_mm=h_pt*25.4/72.0;
      printf "%.2f x %.2f mm", w_mm, h_mm;
      exit
    }
  ')"
  if [[ -z "$page_size_mm" ]]; then
    page_size_mm="unknown"
  fi
fi

qpdf_check_output=""
if ! qpdf_check_output="$(qpdf --check "$src_pdf" 2>&1)"; then
  failures+=("qpdf check failed")
fi

tmp_low="$(mktemp)"
tmp_rgb="$(mktemp)"
tmp_rgb_nonimage="$(mktemp)"
rgb_count=0
low_count=0
rgb_nonimage_count=0

pdfimages -list "$src_pdf" 2> >(grep -Fv "Syntax Warning: GfxUnivariateShading: function with wrong output size" >&2) | awk -v target="$target_dpi" '
  NR <= 2 { next }
  {
    type=$3
    width=$4
    height=$5
    color=$6
    enc=$9
    object=$11
    id=$12
    x=$13
    y=$14
    if (type == "smask") next
    if (x == "" || y == "" || object == "" || id == "") next
    key = "obj-" object "-" id
    lower=tolower(color)
    if (lower == "rgb") {
      printf "%s,%s,%s,%s,%s,%s,%.2f,%.2f\n", key, object, id, color, enc, type, x+0, y+0 >> rgb
      rgb_count++
    }
    if ((x+0) < min || (y+0) < min) {
      min_ppi = (x+0 < y+0) ? x+0 : y+0
      printf "%s,%s,%s,%s,%s,%s,%.2f,%.2f,%.2f,%s,%s\n", key, object, id, color, enc, type, x+0, y+0, min_ppi, width, height >> low
      low_count++
    }
  }
  END {
    printf "%d\n", rgb_count > rgb_count_file
    printf "%d\n", low_count > low_count_file
  }
' min="$min_dpi" rgb="$tmp_rgb" low="$tmp_low" rgb_count_file="${tmp_rgb}.count" low_count_file="${tmp_low}.count"

if [[ -f "${tmp_rgb}.count" ]]; then
  rgb_count="$(cat "${tmp_rgb}.count")"
fi
if [[ -f "${tmp_low}.count" ]]; then
  low_count="$(cat "${tmp_low}.count")"
fi

if [[ "$rgb_count" -gt 0 ]]; then
  failures+=("RGB images remain")
fi
  if [[ "$low_count" -gt 0 ]]; then
    failures+=("low-DPI images remain")
  fi

# Detect RGB usage in non-image PDF objects (e.g., page transparency groups).
qpdf --json "$src_pdf" | jq -r '
  .qpdf[1]
  | to_entries[]
  | .key as $obj
  | .value as $v
  | ($v.stream? | if type == "object" then (.dict? // {}) else {} end) as $sd
  | ($v.value? | if type == "object" then . else {} end) as $vv
  | ((($sd."/Subtype" // $vv."/Subtype" // "") == "/Image")) as $is_image
  | if $is_image then empty else
      [ paths(scalars) as $p
        | (getpath($p)) as $val
        | select($val == "/DeviceRGB" or $val == "/CalRGB")
        | $p
      ] as $paths
      | if ($paths | length) > 0 then
          $obj + "|" + ($paths | map(map(tostring) | join(".")) | join(";"))
        else
          empty
        end
    end
' > "$tmp_rgb_nonimage"

if [[ -s "$tmp_rgb_nonimage" ]]; then
  rgb_nonimage_count="$(wc -l < "$tmp_rgb_nonimage" | tr -d ' ')"
fi
if [[ "$rgb_nonimage_count" -gt 0 ]]; then
  failures+=("RGB non-image objects remain")
fi

echo "Input: $input_pdf"
echo "Normalized: $src_pdf"
echo "Pages (original): ${orig_pages:-unknown}"
echo "Pages (normalized): ${src_pages:-unknown}"
echo "Page size: $page_size_mm"
echo "Target DPI: $target_dpi"
echo "Min DPI (5% margin): $min_dpi"
echo "PDF_STANDARD: $pdf_standard"
echo "COLOR_PROFILE: ${color_profile:-none}"
echo "RGB images: $rgb_count"
echo "RGB non-image objects: $rgb_nonimage_count"
echo "Low-DPI images: $low_count"
if [[ -n "$qpdf_check_output" ]]; then
  echo "qpdf check:"
  echo "$qpdf_check_output" | sed 's/^/  /'
fi
if [[ "$rgb_count" -gt 0 ]]; then
  echo "RGB objects:"
  awk -F, '{printf "  RGB: %s (object %s,%s) color=%s enc=%s type=%s x_ppi=%.2f y_ppi=%.2f\n", $1, $2, $3, $4, $5, $6, $7, $8}' "$tmp_rgb"
fi
if [[ "$low_count" -gt 0 ]]; then
  echo "Low-DPI objects:"
  awk -F, '{printf "  LOW_DPI: %s (object %s,%s) color=%s enc=%s type=%s x_ppi=%.2f y_ppi=%.2f min_ppi=%.2f size=%sx%s\n", $1, $2, $3, $4, $5, $6, $7, $8, $9, $10, $11}' "$tmp_low"
fi
if [[ "$rgb_nonimage_count" -gt 0 ]]; then
  echo "RGB non-image objects (qpdf object|json paths):"
  sed 's/^/  /' "$tmp_rgb_nonimage"
fi
if [[ "${#failures[@]}" -eq 0 ]]; then
  echo "Status: OK"
else
  echo "Status: FAIL"
  for reason in "${failures[@]}"; do
    echo "Reason: $reason"
  done
fi

rm -f "$tmp_low" "$tmp_rgb" "$tmp_rgb_nonimage" "${tmp_low}.count" "${tmp_rgb}.count"

if [[ "${#failures[@]}" -ne 0 ]]; then
  echo "Preflight failed." >&2
  exit 1
fi

exit 0
