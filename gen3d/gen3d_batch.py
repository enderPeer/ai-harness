"""Batch image -> GLB: loads the Hunyuan3D pipeline once, converts many.

Usage: python gen3d_batch.py <out_dir> <img1> [img2 ...]
Each output is <out_dir>/<input-stem>.glb.
"""
import sys
import time
from pathlib import Path

from PIL import Image


def main() -> int:
    if len(sys.argv) < 3:
        print(__doc__)
        return 2
    out_dir = Path(sys.argv[1])
    out_dir.mkdir(parents=True, exist_ok=True)
    inputs = [Path(p) for p in sys.argv[2:]]

    t0 = time.time()
    try:
        from hy3dgen.rembg import BackgroundRemover

        remover = BackgroundRemover()
    except Exception as e:  # noqa: BLE001
        print(f"[batch] no background remover: {e}")
        remover = None

    from hy3dgen.shapegen import Hunyuan3DDiTFlowMatchingPipeline

    pipe = Hunyuan3DDiTFlowMatchingPipeline.from_pretrained("tencent/Hunyuan3D-2")
    print(f"[batch] pipeline loaded ({time.time() - t0:.0f}s)")

    for img_path in inputs:
        t = time.time()
        image = Image.open(img_path).convert("RGBA")
        if remover is not None:
            try:
                image = remover(image)
            except Exception as e:  # noqa: BLE001
                print(f"[batch] rembg failed for {img_path.name}: {e}")
        mesh = pipe(image=image)[0]
        out = out_dir / (img_path.stem + ".glb")
        mesh.export(str(out))
        # Auto-decimate: raw Hunyuan meshes are ~1M faces / 20MB; 8k faces is
        # visually identical at game distance and ~100x smaller.
        try:
            import subprocess

            subprocess.run(
                [sys.executable, str(Path(__file__).parent / "decimate.py"), "8000", str(out)],
                check=True,
                capture_output=True,
            )
        except Exception as e:  # noqa: BLE001
            print(f"[batch] decimation skipped for {out.name}: {e}")
        print(f"[batch] {img_path.name} -> {out.name} ({time.time() - t:.0f}s)")
    print(f"[batch] done, {len(inputs)} meshes in {time.time() - t0:.0f}s")
    return 0


if __name__ == "__main__":
    sys.exit(main())
