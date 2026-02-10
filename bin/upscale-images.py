#!/usr/bin/env python3
import os
import sys
from pathlib import Path
import csv

def eprint(*args, **kwargs):
    print(*args, file=sys.stderr, **kwargs)


def usage():
    eprint("Usage: upscale-images.py <input-pdf> | <input-image>")


def require(cond, msg):
    if not cond:
        eprint(f"ERROR: {msg}")
        sys.exit(1)


def main():
    if len(sys.argv) != 2:
        usage()
        sys.exit(2)

    input_path = Path(sys.argv[1])
    require(input_path.is_file(), f"input file not found: {input_path}")

    try:
        import torch
        import torchvision.transforms.functional as tvf
        import types
        # Shim for older BasicSR expecting torchvision.transforms.functional_tensor
        try:
            import torchvision.transforms.functional_tensor  # noqa: F401
        except ModuleNotFoundError:
            shim = types.ModuleType("torchvision.transforms.functional_tensor")
            shim.__dict__.update(tvf.__dict__)
            sys.modules["torchvision.transforms.functional_tensor"] = shim

        import cv2
        from basicsr.archs.rrdbnet_arch import RRDBNet
        from realesrgan import RealESRGANer
    except Exception as exc:
        eprint("ERROR: Python dependencies missing. Run ./install.sh to set up the venv.")
        eprint(str(exc))
        sys.exit(1)

    if input_path.suffix.lower() == ".pdf":
        base_name = input_path.stem
        low_csv = Path("02-analyze-dpi") / f"{base_name}.lowdpi.images.csv"
        input_dir = Path("03-extract-images") / base_name
        output_dir = Path("04-upscale-images") / base_name
        output_dir.mkdir(parents=True, exist_ok=True)

        require(low_csv.is_file(), f"missing low-DPI image list: {low_csv}")
        require(input_dir.is_dir(), f"missing extracted images directory: {input_dir}")
    else:
        base_name = input_path.stem
        low_csv = None
        input_dir = input_path.parent
        output_dir = input_path.parent

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
    if gpu_id is not None:
        gpu_count = torch.cuda.device_count()
        require(0 <= gpu_id < gpu_count, f"Invalid GPU_ID {gpu_id}. Available range: 0..{gpu_count-1}")
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

    min_scale_env = float(os.environ.get("MIN_SCALE", "1.0"))

    def upscale_one(src_file: Path, final_out: Path, scale_required: float) -> None:
        eprint(f"Upscaling: {src_file} -> {final_out} (scale {scale_required:.4f}, gpu {gpu_id})")
        img = cv2.imread(str(src_file), cv2.IMREAD_COLOR)
        require(img is not None, f"failed to read image: {src_file}")
        eprint(f"  Image shape: {img.shape[1]}x{img.shape[0]}  dtype={img.dtype}")
        scale = scale_required
        while True:
            try:
                output, _ = upsampler.enhance(img, outscale=scale)
                require(cv2.imwrite(str(final_out), output), f"failed to write {final_out}")
                if torch.cuda.is_available():
                    torch.cuda.empty_cache()
                break
            except RuntimeError as exc:
                msg = str(exc)
                if "out of memory" not in msg.lower():
                    raise
                if torch.cuda.is_available():
                    torch.cuda.empty_cache()
                next_scale = scale * 0.9
                if next_scale < min_scale_env:
                    eprint(f"  OOM at scale {scale:.4f}; copying original (min_scale={min_scale_env})")
                    require(cv2.imwrite(str(final_out), img), f"failed to write {final_out}")
                    if torch.cuda.is_available():
                        torch.cuda.empty_cache()
                    return
                eprint(f"  OOM at scale {scale:.4f}; retrying with {next_scale:.4f}")
                scale = next_scale

    if low_csv is None:
        src_file = input_path
        final_out = input_path.with_name(f"{input_path.stem}.up{input_path.suffix}")
        scale_required = float(os.environ.get("SCALE", "2.0"))
        require(scale_required >= 1.0, "SCALE must be >= 1.0")
        upscale_one(src_file, final_out, scale_required)
    else:
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

                upscale_one(src_file, final_out, scale_required)

    print("Done.")


if __name__ == "__main__":
    main()
