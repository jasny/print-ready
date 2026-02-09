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
03-split-pages/
04-rasterize-lowdpi/
05-upscale/
06-rebuild-pages/
07-merge-pages/
08-normalize-pdf/
09-preflight/
10-output/
```

Each step reads only from earlier steps and writes only to its own folder.

## Naming conventions

Input file:

```
00-input/boek.pdf
```

Derived names always preserve the base name `boek`.

Page-based outputs are grouped in a folder named after the document:

```
03-split-pages/boek/p001.pdf
03-split-pages/boek/p002.pdf
```

This applies consistently to all page-based steps.

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
Determine whether any pages contain raster content below the target DPI.

**Definition**

Effective DPI = pixel resolution of a raster image relative to the physical size it is placed at on the page.

**Outputs**

```
02-analyze-dpi/boek.dpi.csv
02-analyze-dpi/boek.lowdpi.pages.txt
```

`boek.lowdpi.pages.txt` contains one page index per line (1-based).

**Fail if**

* DPI analysis cannot be computed

#### Control flow decision

If **no low-DPI pages are found** in step 02:

* Steps **04**, **05**, and **06** are skipped.
* The pipeline continues directly with **step 03 (split pages)** and then jumps to **step 07 (merge pages)**, using only original vector pages.

In other words:

```
02-analyze-dpi
   ├─ low-DPI pages found → 03 → 04 → 05 → 06 → 07
   └─ no low-DPI pages    → 03 → 07
```

This ensures:

* No unnecessary rasterization
* Output remains fully vector where possible

### 03-split-pages

**Purpose**
Split the document into individual page PDFs for selective processing.

**Outputs**

```
03-split-pages/boek/p001.pdf
03-split-pages/boek/p002.pdf
...
```

**Rules**

* Preserve exact page size
* Preserve page order

**Fail if**

* Page count differs from validation step

### 04-rasterize-lowdpi (conditional)

**Purpose**
Rasterize only pages that contain low-DPI raster content.

**Inputs**

* Pages listed in `boek.lowdpi.pages.txt`

**Outputs**

```
04-rasterize-lowdpi/boek/p012.raw.png
04-rasterize-lowdpi/boek.rasterize.txt
```

**Rules**

* Lossless output (PNG or TIFF)
* Fixed render DPI (e.g. 300–400)
* One image per page

### 05-upscale (conditional)

**Purpose**
Upscale rasterized pages so effective resolution meets or exceeds target DPI.

**Strategy**

* Compute required scale factor per page
* Clamp to reasonable bounds (e.g. max x4)
* Do not blindly upscale everything

**Outputs**

```
05-upscale/boek/p012.up.png
05-upscale/boek.upscale.csv
```

**Fail if**

* Upscaler fails
* Output dimensions do not match expected scale

### 06-rebuild-pages (conditional)

**Purpose**
Rebuild page-sized PDFs from upscaled images.

**Outputs**

```
06-rebuild-pages/boek/p012.fixed.pdf
```

**Rules**

* Exact original page size
* Image placed at 100%, no scaling

### 07-merge-pages

**Purpose**
Reassemble a complete document.

**Logic**

For each page index:

* If page was fixed, use `pNNN.fixed.pdf`
* Otherwise, use original `pNNN.pdf`

**Outputs**

```
07-merge-pages/boek.merged.pdf
07-merge-pages/boek.merge.txt
```

**Fail if**

* Page count or page size differs

### 08-normalize-pdf

**Purpose**
Prepare final print-deliverable PDF.

**Typical actions**

* Flatten transparency
* Convert to CMYK
* Export to required PDF standard (e.g. PDF/X-1a)
* Disable resampling

**Outputs**

```
08-normalize-pdf/boek.print.pdf
08-normalize-pdf/boek.normalize.txt
```

### 09-preflight

**Purpose**
Final verification.

**Checks**

* Page count and sizes
* Color space
* Remaining RGB objects
* Remaining low-DPI issues
* File integrity

**Outputs**

```
09-preflight/boek.preflight.txt
```

**Fail if**

* Page sizes differ
* Low-DPI issues remain

### 10-output

**Purpose**
Final deliverables only.

**Contents**

```
10-output/boek.print.pdf
10-output/boek.preflight.txt
10-output/boek.dpi.csv
```

Only this folder is sent to the printer.

## Configuration

All tunable values must live in a single config file:

```
TARGET_DPI=300
RASTERIZE_DPI=400
MAX_UPSCALE=4.0
UPSCALER_MODEL=RealESRGAN_x4plus
IMAGE_FORMAT=png
PDF_STANDARD=PDF/X-1a
COLOR_PROFILE=printer.icc
```

Each report must log the effective configuration used.

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

  * safe PDF splitting and merging
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

  * upscaling rasterized pages that fall below target DPI
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
