"""Decimate GLB meshes in place with quadric edge collapse (pymeshlab).

Usage: python decimate.py <target_faces> <file1.glb> [file2.glb ...]
Writes <file>.glb back (backup at <file>.orig.glb once).
"""
import shutil
import sys
from pathlib import Path

import pymeshlab


def main() -> int:
    if len(sys.argv) < 3:
        print(__doc__)
        return 2
    target = int(sys.argv[1])
    for arg in sys.argv[2:]:
        p = Path(arg)
        backup = p.with_suffix(".orig.glb")
        if "--no-backup" not in sys.argv and not backup.exists():
            shutil.copy2(p, backup)
        ms = pymeshlab.MeshSet()
        ms.load_new_mesh(str(p))
        before = ms.current_mesh().face_number()
        if before > target:
            ms.meshing_decimation_quadric_edge_collapse(
                targetfacenum=target,
                preservenormal=True,
                preservetopology=True,
                qualitythr=0.5,
            )
        # pymeshlab can't write glb: bounce through ply, re-export via trimesh.
        tmp = p.with_suffix(".tmp.ply")
        ms.save_current_mesh(str(tmp))
        import trimesh

        trimesh.load(str(tmp), force="mesh").export(str(p))
        tmp.unlink(missing_ok=True)
        after = ms.current_mesh().face_number()
        size = p.stat().st_size / 1e6
        print(f"[decimate] {p.name}: {before} -> {after} faces, {size:.1f} MB")
    return 0


if __name__ == "__main__":
    sys.exit(main())
