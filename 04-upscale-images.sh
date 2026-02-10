#!/usr/bin/env bash
set -euo pipefail

if [[ ! -d .venv ]]; then
  echo "ERROR: .venv not found. Run ./install.sh first." >&2
  exit 1
fi

. .venv/bin/activate
export PYTORCH_ALLOC_CONF="${PYTORCH_ALLOC_CONF:-expandable_segments:True}"
exec python bin/upscale-images.py "$@"
