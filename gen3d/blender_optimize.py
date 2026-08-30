"""Blender headless mesh optimizer for AI-generated GLBs.

Run: blender --background --python blender_optimize.py -- <in.glb> <out.glb> [target_tris]

Cleanup pass tuned for Hunyuan3D output: merge doubles, drop loose junk,
recalc outside normals, smooth shading with sharp-angle split, optional
decimate to a target triangle count, then export GLB.
"""
import sys

import bpy


def main() -> None:
    argv = sys.argv[sys.argv.index("--") + 1 :]
    src, dst = argv[0], argv[1]
    target_tris = int(argv[2]) if len(argv) > 2 else 0

    bpy.ops.wm.read_factory_settings(use_empty=True)
    bpy.ops.import_scene.gltf(filepath=src)

    meshes = [o for o in bpy.context.scene.objects if o.type == "MESH"]
    if not meshes:
        raise SystemExit("no mesh in " + src)
    # Join into one object for a uniform pass.
    bpy.ops.object.select_all(action="DESELECT")
    for o in meshes:
        o.select_set(True)
    bpy.context.view_layer.objects.active = meshes[0]
    if len(meshes) > 1:
        bpy.ops.object.join()
    obj = bpy.context.view_layer.objects.active

    bpy.ops.object.mode_set(mode="EDIT")
    bpy.ops.mesh.select_all(action="SELECT")
    bpy.ops.mesh.remove_doubles(threshold=0.0005)
    bpy.ops.mesh.delete_loose()
    bpy.ops.mesh.normals_make_consistent(inside=False)
    bpy.ops.object.mode_set(mode="OBJECT")

    tri_count = len(obj.data.loop_triangles) or len(obj.data.polygons) * 2
    if target_tris and tri_count > target_tris:
        mod = obj.modifiers.new("dec", "DECIMATE")
        mod.ratio = max(0.02, target_tris / max(tri_count, 1))
        mod.use_collapse_triangulate = True
        bpy.ops.object.modifier_apply(modifier=mod.name)

    # Smooth shading with sharp-angle preservation. Blender 4.1+ replaced
    # use_auto_smooth with the by-angle operator; keep both paths.
    try:
        bpy.ops.object.shade_smooth_by_angle(angle=0.9)  # ~52 deg
    except AttributeError:
        bpy.ops.object.shade_smooth()
        if hasattr(obj.data, "use_auto_smooth"):
            obj.data.use_auto_smooth = True
            obj.data.auto_smooth_angle = 0.9

    bpy.ops.export_scene.gltf(filepath=dst, export_format="GLB")
    print(f"[blender] {src} -> {dst} ({len(obj.data.polygons)} faces)")


main()
