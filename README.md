# Print-ready PDF pipeline (PowerPoint export)

This project defines a deterministic, folder-based workflow to convert a PDF exported from PowerPoint into a print-ready PDF for **inside pages only**. Covers are explicitly out of scope.

The workflow is designed for Linux, fully scriptable, and suitable for execution by an AI agent.
It is written specifically for Ubuntu LTS; the `00-install.sh` installer relies on APT and will not work on other systems.

The core principles are:

* Deterministic and reproducible output
* One folder per step, no in-place modification
* Filenames always derived from the original input filename
* Full audit trail with reports per step
* Vector pages stay vector whenever possible
* Rasterization and upscaling only where strictly necessary

## Assumptions

* The PowerPoint source already uses the correct final page size.
* Minimum safe margin of **5 mm** is already respected inside PowerPoint.
* The PDF in `00-input` was exported directly from PowerPoint using high-quality settings.
* Inside pages are delivered as **single pages**, not spreads.
* Target effective resolution for raster content is **≥300 dpi** at final size.

## Non-goals

* Editing layout, text, or margins
* Fixing PowerPoint design mistakes
* Cover, spine, bleed, or binding calculations
* Reflowing or reconstructing vector content

## Repository structure

```
00-input/
01-validate/
02-analyze-dpi/
03-extract-images/
04-upscale-images/
05-verify-images/
06-resize-images/
07-resize-smasks/
08-replace-images/
09-normalize-pdf/
10-preflight (stdout only)
```

Each step reads only from earlier steps and writes only to its own folder.

## Running the full pipeline

```
./convert.sh 00-input/boek.pdf
```

Runs steps 1–10 in order and stops on the first failure. All script output is streamed to the terminal.

## Naming conventions

Input file:

```
00-input/boek.pdf
```

Derived names always preserve the base name `boek`.

Image-based outputs are grouped in a folder named after the document:

```
03-extract-images/boek/...
04-upscale-images/boek/...
05-verify-images/boek/...
06-resize-images/boek/...
07-resize-smasks/boek/...
```

## Step-by-step workflow

### 00-input

**Purpose**
Starting point. Contains the PDF exported from PowerPoint.

**Rules**

* Treat as read-only.
* No renaming after ingestion.

**Contents**

```
00-input/boek.pdf
```

### 01-validate

**Purpose**
Sanity check and baseline metadata extraction. No mutation.

**Checks**

* Page count
* Page size consistency
* Encryption
* Basic color space detection
* File hash

**Outputs**

```
01-validate/boek.validated.txt
```

**Fail if**

* Page sizes differ
* PDF is encrypted or unreadable
* Page count is zero

### 02-analyze-dpi

**Purpose**
Identify embedded raster images below the target DPI.

**Definition**

Effective DPI = pixel resolution of a raster image relative to the physical size it is placed at on the page.

**Outputs**

```
02-analyze-dpi/boek.dpi.csv
02-analyze-dpi/boek.lowdpi.images.csv
```

`boek.lowdpi.images.csv` contains one image per line with page number, object id, and DPI.

**Fail if**

* DPI analysis cannot be computed

#### Control flow decision

If **no low-DPI images are found** in step 02:

* Steps **03**, **04**, **05**, **06**, and **07** are skipped.
* The pipeline continues directly with **step 09 (normalize PDF)** using the original PDF.

In other words:

```
02-analyze-dpi
   ├─ low-DPI images found → 03 → 04 → 05 → 06 → 07 → 08 → 09 → 10 → 11
   └─ no low-DPI images    → 09 → 10 → 11
```

This ensures:

* No unnecessary rasterization
* Output remains fully vector where possible

### 03-extract-images (conditional)

**Purpose**
Extract embedded raster images from pages that contain low-DPI content.

**Inputs**

* Images listed in `boek.lowdpi.images.csv`

**Outputs**

```
03-extract-images/boek/obj-<object>-<id>.png
03-extract-images/boek.images.csv
```

**Rules**

* Lossless output (PNG or TIFF)
* Preserve original pixel dimensions

### 04-upscale-images (conditional)

**Purpose**
Upscale only the extracted images so effective resolution meets or exceeds target DPI.

**Strategy**

* Compute required scale factor per image
* Clamp to reasonable bounds (e.g. max x4)
* Do not blindly upscale everything

**Outputs**

```
04-upscale-images/boek/obj-<object>-<id>.up.png
```

**Fail if**

* Upscaler fails
* Output dimensions do not match expected scale

### 05-verify-images (conditional)

**Purpose**
Verify that upscaled images meet the target DPI. Copies any that still fall short.

**Outputs**

```
05-verify-images/boek.verify.csv
05-verify-images/boek/obj-<object>-<id>.up.png
```

### 06-resize-images (conditional)

**Purpose**
Non-AI resize for any images that still miss target DPI after AI upscaling.

**Outputs**

```
06-resize-images/boek/obj-<object>-<id>.up.png
```

### 07-resize-smasks (conditional)

**Purpose**
Resize soft masks (SMask) to match the resized image dimensions.

**Outputs**

```
07-resize-smasks/boek/obj-<object>-<id>.up.png
```

### 08-replace-images (conditional)

**Purpose**
Replace the original low-DPI image objects in the PDF with the upscaled versions, preserving vector content.
Replacement images are converted to **CMYK** to avoid color conversion during normalization.

**Outputs**

```
08-replace-images/boek.replaced.pdf
08-replace-images/boek.replace.txt
```

### 09-normalize-pdf

**Purpose**
Prepare final print-deliverable PDF.

**Typical actions**

* Flatten transparency
* Convert to CMYK
* Export to required PDF standard (e.g. PDF/X-1a)
* Disable resampling

**Outputs**

```
09-normalize-pdf/boek.print.pdf
09-normalize-pdf/boek.normalize.txt
```

### 10-preflight

**Purpose**
Final verification.

**Checks**

* Page count and sizes
* Color space
* Remaining RGB objects
* Remaining low-DPI issues
* File integrity

**Outputs**

Prints to stdout only.

**Fail if**

* Page sizes differ
* Low-DPI issues remain

The final deliverable remains in `09-normalize-pdf/`.

## Configuration

All tunable values must live in a single config file:

```
TARGET_DPI=300
RASTERIZE_DPI=400
MAX_UPSCALE=4.0
UPSCALER_MODEL=RealESRGAN_x4plus
IMAGE_FORMAT=png
PDF_STANDARD=PDF/X-4
COLOR_PROFILE=printer.icc
```

Each report must log the effective configuration used.

## Print Specs Summary (New Energy)

These requirements are summarized from New Energy’s Dutch print delivery specifications and are provided for convenience (inside pages only; covers are out of scope here).

- Images should be **≥300 dpi**; below **240 dpi** risks visible quality loss. Avoid web‑sourced images due to low quality/rights.
- Add **3 mm bleed** for inside pages; bleed artwork must extend into the bleed area.
- Minimum line thickness: **0.1 mm** (or **0.4 mm** for foil finishes).
- **Flatten transparency** and export as **PDF/X-1a:2001** for print delivery.
- Use **CMYK only** (no RGB); total ink coverage should not exceed **280%**.
- Deep black (typically for covers): **C50 M40 Y40 K100**. Text/line art in body should be **K100 only**.
- Include **trim marks** on export; keep offsets outside the bleed.
- Deliver **cPDF** (certified PDF) and export using PDF/X‑1a:2001 presets.

## Agent instructions

An AI agent working on this repository must:

* Never modify files in place
* Always write outputs to the next step folder
* Fail fast on invariant violations
* Skip steps cleanly when no-op conditions apply
* Produce human-readable reports at every step

Here is the **clean, final list of required tools**, aligned with the workflow as described. No extras, no overlap.

## Required tools (core)

These are needed to run the pipeline end to end.

### PDF inspection and manipulation

* **poppler-utils**
  Used for:

  * `pdfinfo`, page size and page count
  * `pdfimages`, extracting embedded raster images
  * `pdftoppm`, rasterizing pages

* **ghostscript**
  Used for:

  * transparency flattening
  * CMYK conversion
  * PDF/X export
  * final print normalization

* **qpdf**
  Used for:

  * safe PDF object inspection and replacement
  * sanity checks
  * metadata inspection

### Image inspection and processing

* **ImageMagick**
  Used for:

  * verifying image dimensions
  * confirming DPI after rasterization and upscaling
  * format conversion (PNG, TIFF)

* **exiftool**
  Used for:

  * inspecting image metadata
  * validating DPI and color info in images

### AI upscaling

* **Real-ESRGAN** (external, not via apt)
  Used for:

  * upscaling extracted raster images that fall below target DPI
  * GPU-accelerated where available

Recommended model:

* `RealESRGAN_x4plus`

### Scripting and orchestration

* **bash**
  Primary orchestration language.

* **coreutils** (`sed`, `awk`, `grep`, `cut`, `sort`, `uniq`, `wc`)
  Used for:

  * parsing reports
  * page list generation
  * control flow decisions

* **jq** (optional but recommended)
  Used if DPI reports are emitted as JSON instead of CSV.
