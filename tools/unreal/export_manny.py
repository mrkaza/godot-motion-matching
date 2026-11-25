# Exports the UE5 Manny (SKM_Manny_Simple) as FBX with Unreal's own exporter and default options.
# Runs in the full editor (extract_gasp.ps1, step 2): the FBX exporter CPU-skins the mesh in a temporary
# world for material baking data (FbxSkeletalMeshExport.cpp:350), which fails without a renderer, so the
# headless export (export_gasp.py) can't do it. Quits the editor when done.
import os, unreal

OUT = os.environ.get("GASP_OUT") or os.path.join(os.path.dirname(os.path.abspath(__file__)), "out")
MESH = "/Game/Characters/UE5_Mannequins/Meshes/SKM_Manny_Simple"

try:
    path = os.path.join(OUT, "mesh", "SKM_Manny_Simple.fbx")
    os.makedirs(os.path.dirname(path), exist_ok=True)
    t = unreal.AssetExportTask()
    t.object = unreal.load_asset(MESH)
    t.filename = path
    t.automated = True
    t.prompt = False
    t.replace_identical = True
    t.exporter = unreal.SkeletalMeshExporterFBX()
    t.options = unreal.FbxExportOption()
    ok = t.object is not None and unreal.Exporter.run_asset_export_task(t)
    unreal.log("GASP manny %s" % ("written" if ok and os.path.exists(path) else "FAILED"))
finally:
    unreal.SystemLibrary.quit_editor()
