#!/usr/bin/env bash
set -euo pipefail

if [[ "$(id -u)" -ne 0 ]]; then
  SUDO="sudo"
else
  SUDO=""
fi

$SUDO apt-get update
$SUDO apt-get install -y --no-install-recommends \
  poppler-utils \
  ghostscript \
  qpdf \
  imagemagick \
  exiftool \
  jq \
  coreutils \
  bash \
  curl \
  git \
  unzip \
  zint \
  zxing-cpp-tools \
  ca-certificates \
  python3 \
  python3-venv \
  python3-pip \
  vulkan-tools \
  libvulkan1 \
  liblcms2-2 \
  ripgrep

REAL_ESRGAN_VERSION="v0.2.5.0"
REAL_ESRGAN_ZIP="realesrgan-ncnn-vulkan-20220424-ubuntu.zip"
REAL_ESRGAN_URL="https://github.com/xinntao/Real-ESRGAN/releases/download/${REAL_ESRGAN_VERSION}/${REAL_ESRGAN_ZIP}"
INSTALL_ROOT="/opt/real-esrgan"
INSTALL_DIR="${INSTALL_ROOT}/${REAL_ESRGAN_VERSION}"

$SUDO mkdir -p "${INSTALL_DIR}"

if ! find "${INSTALL_DIR}" -type f -name realesrgan-ncnn-vulkan -print -quit | grep -q .; then
  tmp_dir="$(mktemp -d)"
  curl -L "${REAL_ESRGAN_URL}" -o "${tmp_dir}/${REAL_ESRGAN_ZIP}"
  $SUDO unzip -q "${tmp_dir}/${REAL_ESRGAN_ZIP}" -d "${INSTALL_DIR}"
fi

PYTHON_BIN="${PYTHON_BIN:-python3}"
if ! command -v "$PYTHON_BIN" >/dev/null; then
  echo "ERROR: Python interpreter '$PYTHON_BIN' was not found." >&2
  exit 1
fi

python_version="$($PYTHON_BIN -c 'import sys; print(f"{sys.version_info.major}.{sys.version_info.minor}")')"
case "$python_version" in
  3.10|3.11|3.12) ;;
  *)
    echo "ERROR: Real-ESRGAN's BasicSR dependency supports Python 3.10–3.12; found Python $python_version." >&2
    echo "Install a supported interpreter, remove .venv, then rerun with e.g. PYTHON_BIN=python3.12 ./install.sh." >&2
    exit 1
    ;;
esac

if [[ -d .venv ]]; then
  venv_version="$(.venv/bin/python -c 'import sys; print(f"{sys.version_info.major}.{sys.version_info.minor}")')"
  if [[ "$venv_version" != "$python_version" ]]; then
    echo "ERROR: .venv uses Python $venv_version, but $PYTHON_BIN uses Python $python_version." >&2
    echo "Remove .venv and rerun the installer to create it with the selected interpreter." >&2
    exit 1
  fi
else
  "$PYTHON_BIN" -m venv .venv
fi

. .venv/bin/activate
python -m pip install --upgrade pip
python -m pip install torch torchvision torchaudio opencv-python pikepdf pillow
# PyPI Real-ESRGAN first resolves the legacy BasicSR source release, which fails
# with current setuptools. Install the maintained revision before Real-ESRGAN.
python -m pip install --upgrade "basicsr @ git+https://github.com/XPixelGroup/BasicSR@8d56e3a045f9fb3e1d8872f92ee4a4f07f886b0a"
python -m pip install --no-deps realesrgan

mkdir -p weights
if [[ ! -f weights/RealESRGAN_x4plus.pth ]]; then
  curl -L "https://github.com/xinntao/Real-ESRGAN/releases/download/v0.2.1/RealESRGAN_x4plus.pth" -o weights/RealESRGAN_x4plus.pth
fi
if [[ ! -f weights/RealESRGAN_x2plus.pth ]]; then
  curl -L "https://github.com/xinntao/Real-ESRGAN/releases/download/v0.2.1/RealESRGAN_x2plus.pth" -o weights/RealESRGAN_x2plus.pth
fi

iso300_dst="/usr/share/color/icc/colord/ISOcoated_v2_300_eci.icc"
if [[ ! -f "$iso300_dst" ]]; then
  tmp_dir="$(mktemp -d)"
  zip_path="${tmp_dir}/eci_offset_2009.zip"
  if ! curl -fL "https://eci.org/lib/exe/eci_offset_2009.zip" -o "$zip_path"; then
    curl -fL "https://www.eci.org/lib/exe/eci_offset_2009.zip" -o "$zip_path"
  fi
  unzip -q "$zip_path" -d "$tmp_dir"
  iso300_src="$(find "$tmp_dir" -type f -name 'ISOcoated_v2_300_eci.icc' -print -quit)"
  if [[ -z "$iso300_src" ]]; then
    echo "ERROR: ISOcoated_v2_300_eci.icc not found in downloaded archive" >&2
    exit 1
  fi
  $SUDO install -m 0644 "$iso300_src" "$iso300_dst"
fi

BIN_PATH="$(find "${INSTALL_DIR}" -type f -name realesrgan-ncnn-vulkan -print -quit)"
if [[ -n "${BIN_PATH}" ]]; then
  $SUDO chmod +x "${BIN_PATH}"
  if [[ ! -e /usr/local/bin/realesrgan-ncnn-vulkan ]]; then
    $SUDO ln -s "${BIN_PATH}" /usr/local/bin/realesrgan-ncnn-vulkan
  fi
fi
