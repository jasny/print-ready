# Repository Guidelines

## Project Structure & Module Organization
This repository defines a stepwise, folder-based PDF pipeline. Each step reads from earlier folders and writes only to its own folder. Key directories:

- `00-input/` source PDFs exported from PowerPoint (read-only)
- `01-validate/` validation reports
- `02-analyze-dpi/` DPI analysis and low-DPI page lists
- `03-extract-images/` extracted raster images and metadata
- `04-upscale-images/` upscaled images and CSVs
- `05-verify-images/` reports and images that still miss target DPI
- `06-replace-images/` PDFs with replaced image objects
- `07-normalize-pdf/` print-ready normalization outputs
- `08-preflight/` final verification reports
- `09-output/` deliverables only

## Build, Test, and Development Commands
No build or test commands are defined in this repo. The workflow is documented in `README.md`, and execution is expected to be script-driven by downstream tooling. If you add scripts later, document them here with examples such as:

- `./scripts/run-pipeline.sh 00-input/boek.pdf` — run the full pipeline

## Coding Style & Naming Conventions
- Use deterministic, folder-per-step outputs; never modify files in place.
- Filenames are derived from the original input base name (e.g., `boek`).
- Page artifacts use zero-padded page numbers: `p001`, `p002`, etc.
- Reports are text/CSV and stored per step (e.g., `01-validate/boek.validated.txt`).

## Testing Guidelines
No automated tests are currently specified. Validation is performed via the pipeline reports. If tests are added, prefer a `tests/` directory and document the command (e.g., `pytest` or `npm test`).

## Commit & Pull Request Guidelines
**Commits**
- Use concise, imperative subjects: `Add DPI analyzer`, `Fix replace step logging`.
- Optional scope prefix if helpful: `pipeline: Add preflight check`.
- Keep subjects under ~72 characters; add details in the body when needed.

**Pull Requests**
- Describe the change and which pipeline step(s) are affected.
- Include sample artifacts or report snippets when behavior changes.
- Call out skipped steps (e.g., no low-DPI pages found).

## Agent-Specific Instructions
- Never modify files in place; only write to the appropriate step folder.
- Fail fast on invariant violations (page size changes, encryption, missing pages).
- Skip conditional steps cleanly when no low-DPI pages are detected.
- Produce human-readable reports at every step.
- Create a Git commit after each task you complete for the user.
- Only rely on tools that are installed by the repository's installer (plus standard Ubuntu tools). If a non-standard tool is required, add it to the installer first.
