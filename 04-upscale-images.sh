#!/usr/bin/env bash
set -euo pipefail

if [[ ! -d .venv ]]; then
  echo "ERROR: .venv not found. Run ./install.sh first." >&2
  exit 1
fi

. .venv/bin/activate
export PYTHONPATH="$(pwd)/compat${PYTHONPATH:+:$PYTHONPATH}"
exec python bin/upscale-images.py "$@"
