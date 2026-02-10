#!/usr/bin/env python3
import os
import sys
from pathlib import Path

# Re-exec using venv python before heavy imports.
if os.environ.get("VIRTUAL_ENV") is None:
    venv_python = Path(".venv") / "bin" / "python"
    if venv_python.exists():
        os.execv(str(venv_python), [str(venv_python), *sys.argv])

import csv

def eprint(*args, **kwargs):
    print(*args, file=sys.stderr, **kwargs)


def usage():
    eprint("Usage: 04-upscale-images.py <input-pdf>")


def require(cond, msg):
    if not cond:
        eprint(f"ERROR: {msg}")
        sys.exit(1)


def main():
    if len(sys.argv) != 2:
        usage()
        sys.exit(2)

    input_pdf = Path(sys.argv[1])
    require(input_pdf.is_file(), f"input file not found: {input_pdf}")

    try:
        import torch
        import cv2
        from basicsr.archs.rrdbnet_arch import RRDBNet
        from realesrgan import RealESRGANer
    except Exception as exc:
        eprint("ERROR: Python dependencies missing. Run ./install.sh to set up the venv.")
        eprint(str(exc))
        sys.exit(1)

    base_name = input_pdf.stem
    low_csv = Path("02-analyze-dpi") / f"{base_name}.lowdpi.images.csv"
    input_dir = Path("03-extract-images") / base_name
    output_dir = Path("04-upscale-images") / base_name
    output_dir.mkdir(parents=True, exist_ok=True)

    require(low_csv.is_file(), f"missing low-DPI image list: {low_csv}")
    require(input_dir.is_dir(), f"missing extracted images directory: {input_dir}")

    force_cpu = os.environ.get("FORCE_CPU") == "1"
    gpu_id_env = os.environ.get("GPU_ID")

    if force_cpu:
        if torch.cuda.is_available():
            eprint("FORCE_CPU=1 set. Running on CPU.")
        gpu_id = None
        use_half = False
    else:
        if not torch.cuda.is_available():
            eprint("ERROR: CUDA GPU not available. This run will not use the GPU.")
            eprint("Hint: activate the venv and verify: python -c 'import torch; print(torch.cuda.is_available())'")
            sys.exit(1)
        if gpu_id_env:
            gpu_id = int(gpu_id_env)
        else:
            gpu_count = torch.cuda.device_count()
            if gpu_count == 1:
                gpu_id = 0
            else:
                eprint("Available GPUs:")
                for idx in range(gpu_count):
                    eprint(f"GPU{idx}: {torch.cuda.get_device_name(idx)}")
                require(False, "GPU_ID is required when multiple GPUs are present.")
        use_half = True

    target_dpi = float(os.environ.get("TARGET_DPI", "300"))
    max_upscale = float(os.environ.get("MAX_UPSCALE", "4.0"))
    model_name = os.environ.get("UPSCALER_MODEL", "RealESRGAN_x4plus")
    weights_dir = Path("weights")
    weights_path = weights_dir / f"{model_name}.pth"
    require(weights_path.is_file(), f"missing model weights: {weights_path}")

    model = RRDBNet(num_in_ch=3, num_out_ch=3, num_feat=64, num_block=23, num_grow_ch=32, scale=4)
    eprint(f"Using GPU_ID={gpu_id} ({torch.cuda.get_device_name(gpu_id)})")
    upsampler = RealESRGANer(
        scale=4,
        model_path=str(weights_path),
        model=model,
        tile=0,          # no tiling
        tile_pad=10,
        pre_pad=0,
        half=use_half,
        gpu_id=gpu_id,
    )

    seen = set()

    with low_csv.open(newline="") as fh:
        reader = csv.DictReader(fh)
        for row in reader:
            image_key = row.get("image_key")
            if not image_key or image_key in seen:
                continue
            seen.add(image_key)

            src_file = input_dir / f"{image_key}.png"
            if not src_file.is_file():
                continue

            final_out = output_dir / f"{image_key}.up.png"
            if final_out.is_file():
                continue

            min_ppi = float(row.get("min_ppi") or 0)
            if min_ppi <= 0:
                continue

            scale_required = max(1.0, min(target_dpi / min_ppi, max_upscale))
            if scale_required <= 1.0:
                continue

            eprint(f"Upscaling: {src_file} -> {final_out} (scale {scale_required:.4f}, gpu {gpu_id})")

            img = cv2.imread(str(src_file), cv2.IMREAD_COLOR)
            require(img is not None, f"failed to read image: {src_file}")
            eprint(f"  Image shape: {img.shape[1]}x{img.shape[0]}  dtype={img.dtype}")

            output, _ = upsampler.enhance(img, outscale=scale_required)
            require(cv2.imwrite(str(final_out), output), f"failed to write {final_out}")

    print("Done.")


if __name__ == "__main__":
    main()
