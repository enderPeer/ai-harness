"""Multi-view image -> GLB via Hunyuan3D-2mv (much better backs/sides than
single-view). Usage:

  python gen3d_mv.py <out.glb> <front.png> [back.png] [left.png] [right.png]

Missing views are simply omitted (front is required).
"""
import sys
import time
from pathlib import Path

from PIL import Image

VIEWS = ["front", "back", "left", "right"]


def main() -> int:
    if len(sys.argv) < 3:
        print(__doc__)
        return 2
    out = Path(sys.argv[1])
    t0 = time.time()

    try:
        from hy3dgen.rembg import BackgroundRemover

        remover = BackgroundRemover()
    except Exception as e:  # noqa: BLE001
        print(f"[mv] no background remover: {e}")
        remover = None

    images = {}
    for view, arg in zip(VIEWS, sys.argv[2:]):
        img = Image.open(arg).convert("RGBA")
        if remover is not None:
            try:
                img = remover(img)
            except Exception as e:  # noqa: BLE001
                print(f"[mv] rembg failed for {view}: {e}")
        images[view] = img
    print(f"[mv] views: {list(images)} ({time.time() - t0:.0f}s)")

    from hy3dgen.shapegen import Hunyuan3DDiTFlowMatchingPipeline

    # Multi-view model: its own repo with a distinct subfolder.
    pipe = Hunyuan3DDiTFlowMatchingPipeline.from_pretrained(
        "tencent/Hunyuan3D-2mv", subfolder="hunyuan3d-dit-v2-mv"
    )
    print(f"[mv] pipeline loaded ({time.time() - t0:.0f}s)")

    mesh = pipe(image=images)[0]
    mesh.export(str(out))
    # Decimate in place (higher budget than parts: hero asset).
    import subprocess

    subprocess.run(
        [sys.executable, str(Path(__file__).parent / "decimate.py"), "30000", str(out), "--no-backup"],
        check=False,
    )
    print(f"[mv] wrote {out} ({time.time() - t0:.0f}s total)")
    return 0


if __name__ == "__main__":
    sys.exit(main())
