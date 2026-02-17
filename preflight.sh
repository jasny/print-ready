#!/usr/bin/env bash
set -euo pipefail
export LC_ALL=C

usage() {
  echo "Usage: $0 <pdf-file>" >&2
}

if [[ $# -ne 1 ]]; then
  usage
  exit 2
fi

src_pdf="$1"
if [[ ! -f "$src_pdf" ]]; then
  echo "ERROR: input file not found: $src_pdf" >&2
  exit 1
fi

target_dpi="${TARGET_DPI:-300}"
min_dpi="$(awk -v t="$target_dpi" 'BEGIN { printf "%.2f", t * 0.95 }')"
trim_margin_mm="${TRIM_MARGIN_MM:-3}"
trim_margin_pt="$(awk -v m="$trim_margin_mm" 'BEGIN { printf "%.6f", m*72.0/25.4 }')"
trim_tolerance_pt="${TRIM_TOLERANCE_PT:-0.6}"
pdf_standard="${PDF_STANDARD:-PDF/X-4}"
default_profile="${DEFAULT_COLOR_PROFILE:-/usr/share/color/icc/colord/FOGRA39L_coated.icc}"
color_profile="${COLOR_PROFILE:-$default_profile}"

failures=()

src_info="$(pdfinfo "$src_pdf")"

src_pages="$(echo "$src_info" | awk -F: '/^Pages:/ {gsub(/^[ \t]+/,"",$2); print $2}')"

if [[ -z "$src_pages" || "$src_pages" -le 0 ]]; then
  failures+=("page count is invalid")
fi

page_size_mismatch=""
trim_mismatch=""
if [[ "${#failures[@]}" -eq 0 ]]; then
  for ((i=1; i<=src_pages; i++)); do
    box_info="$(pdfinfo -f "$i" -l "$i" -box "$src_pdf")"
    norm_size="$(echo "$box_info" | awk -v p="$i" '$1=="Page" && $2==p && $3=="size:" {print $4" x "$6" pts"; exit}')"
    if [[ -z "$norm_size" ]]; then
      page_size_mismatch="failed to read page size for page $i"
      break
    fi

    media_vals="$(echo "$box_info" | awk -v p="$i" '$1=="Page" && $2==p && $3=="MediaBox:" {print $4" "$5" "$6" "$7; exit}')"
    trim_vals="$(echo "$box_info" | awk -v p="$i" '$1=="Page" && $2==p && $3=="TrimBox:" {print $4" "$5" "$6" "$7; exit}')"
    if [[ -z "$media_vals" || -z "$trim_vals" ]]; then
      trim_mismatch="failed to read MediaBox/TrimBox for page $i"
      break
    fi
    read -r mx0 my0 mx1 my1 <<< "$media_vals"
    read -r tx0 ty0 tx1 ty1 <<< "$trim_vals"
    trim_check="$(awk -v mx0="$mx0" -v my0="$my0" -v mx1="$mx1" -v my1="$my1" \
      -v tx0="$tx0" -v ty0="$ty0" -v tx1="$tx1" -v ty1="$ty1" \
      -v inset="$trim_margin_pt" -v tol="$trim_tolerance_pt" '
      function abs(x){return x<0?-x:x}
      BEGIN{
        ok=1
        if (abs((tx0-mx0)-inset)>tol) ok=0
        if (abs((ty0-my0)-inset)>tol) ok=0
        if (abs((mx1-tx1)-inset)>tol) ok=0
        if (abs((my1-ty1)-inset)>tol) ok=0
        if (ok) print "OK"; else printf "BAD %.3f %.3f %.3f %.3f", (tx0-mx0), (ty0-my0), (mx1-tx1), (my1-ty1)
      }')"
    if [[ "$trim_check" != "OK" ]]; then
      trim_mismatch="page $i trim inset mismatch (${trim_check#BAD }) expected ${trim_margin_mm}mm"
      break
    fi
  done
fi
if [[ -n "$page_size_mismatch" ]]; then
  failures+=("$page_size_mismatch")
fi
if [[ -n "$trim_mismatch" ]]; then
  failures+=("$trim_mismatch")
fi

page_size_mm="unknown"
trim_size_mm="unknown"
if [[ -n "$src_pages" && "$src_pages" -gt 0 ]]; then
  box_1="$(pdfinfo -f 1 -l 1 -box "$src_pdf")"
  page_size_mm="$(echo "$box_1" | awk '
    $1=="Page" && $2==1 && $3=="size:" {
      w_pt=$4+0; h_pt=$6+0;
      w_mm=w_pt*25.4/72.0;
      h_mm=h_pt*25.4/72.0;
      printf "%.2f x %.2f mm", w_mm, h_mm;
      exit
    }
  ')"
  trim_size_mm="$(echo "$box_1" | awk '
    $1=="Page" && $2==1 && $3=="TrimBox:" {
      w_pt=($6-$4)+0; h_pt=($7-$5)+0;
      w_mm=w_pt*25.4/72.0;
      h_mm=h_pt*25.4/72.0;
      printf "%.2f x %.2f mm", w_mm, h_mm;
      exit
    }
  ')"
  if [[ -z "$page_size_mm" ]]; then
    page_size_mm="unknown"
  fi
  if [[ -z "$trim_size_mm" ]]; then
    trim_size_mm="unknown"
  fi
fi

qpdf_check_output=""
if ! qpdf_check_output="$(qpdf --check "$src_pdf" 2>&1)"; then
  failures+=("qpdf check failed")
fi

tmp_low="$(mktemp)"
tmp_rgb="$(mktemp)"
tmp_rgb_nonimage="$(mktemp)"
tmp_rgb_ops="$(mktemp)"
tmp_shading_mismatch="$(mktemp)"
rgb_count=0
low_count=0
rgb_nonimage_count=0
rgb_ops_count=0
shading_mismatch_count=0

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

# Detect RGB paint operators in content streams (e.g., vector/text graphics).
tmp_qdf="$(mktemp --suffix=.qdf.pdf)"
qpdf --qdf --object-streams=disable --stream-data=uncompress "$src_pdf" "$tmp_qdf"
grep -aEn '(^|[^0-9.])([0-9]+(\.[0-9]+)?)[[:space:]]+([0-9]+(\.[0-9]+)?)[[:space:]]+([0-9]+(\.[0-9]+)?)[[:space:]]+(rg|RG)([^A-Za-z]|$)' "$tmp_qdf" > "$tmp_rgb_ops" || true
if [[ -s "$tmp_rgb_ops" ]]; then
  rgb_ops_count="$(wc -l < "$tmp_rgb_ops" | tr -d ' ')"
fi
if [[ "$rgb_ops_count" -gt 0 ]]; then
  failures+=("RGB content operators remain")
fi

# Detect shading/function component mismatches (often rejected by strict viewers/RIPs).
qpdf --json "$src_pdf" | jq -r '
  def objdict($objs; $r):
      if ($r | type) == "string" and ($r | test("^[0-9]+ 0 R$")) then
        (($objs["obj:" + $r].value // $objs["obj:" + $r].stream.dict) // null)
      elif ($r | type) == "object" then
        $r
      else
        null
      end;
  def cs_components($objs; $cs):
      if $cs == "/DeviceCMYK" then 4
      elif ($cs == "/DeviceRGB" or $cs == "/CalRGB") then 3
      elif $cs == "/DeviceGray" then 1
      elif (($cs | type) == "array" and ($cs | length) >= 2 and $cs[0] == "/ICCBased") then
        ((objdict($objs; $cs[1]) | ."/N"?) // null)
      else
        null
      end;
  def fn_outputs($objs; $fn):
      (objdict($objs; $fn)) as $f
      | if ($f | type) != "object" then null
        elif ($f."/FunctionType"? == 2) then
          ((($f."/C0"? // []) | length) as $c0
            | (($f."/C1"? // []) | length) as $c1
            | if $c0 > 0 then $c0 elif $c1 > 0 then $c1 else 1 end)
        elif ($f."/FunctionType"? == 0) then
          (((($f."/Range"? // []) | length) / 2) | floor)
        elif ($f."/FunctionType"? == 3) then
          (($f."/Functions"? // [])
            | map(fn_outputs($objs; .))
            | map(select(. != null))
            | if length > 0 then max else null end)
        else
          null
        end;
  .qpdf[1] as $objs
  | $objs
  | to_entries[]
  | .key as $obj_key
  | ((.value.value // .value.stream.dict) // {}) as $d
  | select($d."/ShadingType"? != null)
  | (cs_components($objs; $d."/ColorSpace"?) // null) as $csn
  | (fn_outputs($objs; $d."/Function"?) // null) as $fout
  | select($csn != null and $fout != null and $csn != $fout)
  | "\($obj_key)|Shading colorspace components=\($csn), function outputs=\($fout)"
' > "$tmp_shading_mismatch"
if [[ -s "$tmp_shading_mismatch" ]]; then
  shading_mismatch_count="$(wc -l < "$tmp_shading_mismatch" | tr -d ' ')"
fi
if [[ "$shading_mismatch_count" -gt 0 ]]; then
  failures+=("shading/function component mismatches remain")
fi

echo "File: $src_pdf"
echo "Pages: ${src_pages:-unknown}"
echo "Page size: $page_size_mm"
echo "Trim size: $trim_size_mm"
echo "Trim margin target (mm): $trim_margin_mm"
echo "Target DPI: $target_dpi"
echo "Min DPI (5% margin): $min_dpi"
echo "PDF_STANDARD: $pdf_standard"
echo "COLOR_PROFILE: ${color_profile:-none}"
echo "RGB images: $rgb_count"
echo "RGB non-image objects: $rgb_nonimage_count"
echo "RGB content operators (rg/RG): $rgb_ops_count"
echo "Shading/function mismatches: $shading_mismatch_count"
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
if [[ "$rgb_ops_count" -gt 0 ]]; then
  echo "RGB content operator matches (first 20):"
  sed -n '1,20p' "$tmp_rgb_ops" | sed 's/^/  /'
fi
if [[ "$shading_mismatch_count" -gt 0 ]]; then
  echo "Shading/function mismatches:"
  sed 's/^/  /' "$tmp_shading_mismatch"
fi
if [[ "${#failures[@]}" -eq 0 ]]; then
  echo "Status: OK"
else
  echo "Status: FAIL"
  for reason in "${failures[@]}"; do
    echo "Reason: $reason"
  done
fi

rm -f "$tmp_low" "$tmp_rgb" "$tmp_rgb_nonimage" "$tmp_rgb_ops" "$tmp_shading_mismatch" "$tmp_qdf" "${tmp_low}.count" "${tmp_rgb}.count"

if [[ "${#failures[@]}" -ne 0 ]]; then
  echo "Preflight failed." >&2
  exit 1
fi

exit 0
