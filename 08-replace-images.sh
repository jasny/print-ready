#!/usr/bin/env bash
set -euo pipefail

if [[ ! -d .venv ]]; then
  echo "ERROR: .venv not found. Run ./install.sh first." >&2
  exit 1
fi

. .venv/bin/activate
exec python bin/replace-images.py "$@"
