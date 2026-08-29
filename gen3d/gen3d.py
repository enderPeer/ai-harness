"""Image -> GLB via Hunyuan3D-2 shape generation (shape only, ~10GB VRAM).

Usage: python gen3d.py <input_image> <output.glb> [model_repo]
Default model: tencent/Hunyuan3D-2mini (fast geometry). Use
tencent/Hunyuan3D-2 for higher quality.
"""
import sys
import time

from PIL import Image


def main() -> int:
    if len(sys.argv) < 3:
        print(__doc__)
        return 2
    img_path, out_path = sys.argv[1], sys.argv[2]
    model = sys.argv[3] if len(sys.argv) > 3 else "tencent/Hunyuan3D-2"

    t0 = time.time()
    image = Image.open(img_path).convert("RGBA")

    # Concept renders have a solid background; strip it so the shape model
    # sees a clean silhouette. Optional dependency - degrade gracefully.
    try:
        from hy3dgen.rembg import BackgroundRemover

        image = BackgroundRemover()(image)
        print(f"[gen3d] background removed ({time.time() - t0:.1f}s)")
    except Exception as e:  # noqa: BLE001
        print(f"[gen3d] background removal skipped: {e}")

    from hy3dgen.shapegen import Hunyuan3DDiTFlowMatchingPipeline

    pipe = Hunyuan3DDiTFlowMatchingPipeline.from_pretrained(model)
    print(f"[gen3d] pipeline loaded ({time.time() - t0:.1f}s)")

    mesh = pipe(image=image)[0]
    mesh.export(out_path)
    print(f"[gen3d] wrote {out_path} ({time.time() - t0:.1f}s total)")
    return 0


if __name__ == "__main__":
    sys.exit(main())
