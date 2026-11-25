# Exports everything the Godot port needs from Unreal's Game Animation Sample.
# Runs inside the Unreal editor (headless). Started by tools/extract_gasp.ps1, which sets:
#   GASP_OUT    folder to write into (the Godot project's extracted/ folder)
#   GASP_LIMIT  optional: export only this many assets of each kind (quick test)
#
# Writes:
#   anims/<sample folders>/<name>.fbx        every AnimSequence of the UEFN mannequin
#   mesh/SKM_UEFN_Mannequin.glb              the mannequin (glTF, see step 2)
#   t3d/<sample path>.t3d                    full property dump (UTF-8) of every sequence (notifies, curves, sync markers),
#                                            database, schema, chooser, montage, blend space, physics asset, curve,
#                                            struct, enum, and every blueprint with all its graphs and nodes
#   sequences.json                           per sequence: length, frame count, frame rate, root motion
#   manifest.json                            counts and every file written
#   audio/                                   the foley sound waves (WAV) and foley_bank.json (export_audio.py)
#   data/retarget.json                       how the sample retargets the mannequin onto Manny (export_retarget.py)
import json, os, unreal

OUT = os.environ.get("GASP_OUT") or os.path.join(os.path.dirname(os.path.abspath(__file__)), "out")
LIMIT = int(os.environ.get("GASP_LIMIT") or 0)
SKIP_ANIMS = os.environ.get("GASP_SKIP_ANIMS") == "1"   # rerun the data export without re-exporting clips

MANNEQUIN = "/Game/Characters/UEFN_Mannequin"
ANIMS = MANNEQUIN + "/Animations"
MESH = MANNEQUIN + "/Meshes/SKM_UEFN_Mannequin"

# Asset classes dumped as T3D text: (module, class, search roots)
T3D_CLASSES = [
    ("PoseSearch", "PoseSearchDatabase", ["/Game"]),
    ("PoseSearch", "PoseSearchSchema", ["/Game"]),
    ("PoseSearch", "PoseSearchNormalizationSet", ["/Game"]),
    ("PoseSearch", "PoseSearchInteractionAsset", ["/Game"]),      # paired shoves, tackles, takedowns
    ("Chooser", "ChooserTable", ["/Game"]),
    ("ProxyTable", "ProxyTable", ["/Game"]),
    ("ProxyTable", "ProxyAsset", ["/Game"]),
    ("Engine", "AnimMontage", [MANNEQUIN]),
    ("Engine", "BlendSpace", [MANNEQUIN]),
    ("Engine", "BlendSpace1D", [MANNEQUIN]),
    ("Engine", "AimOffsetBlendSpace", [MANNEQUIN]),
    ("Engine", "PoseAsset", [MANNEQUIN]),
    ("Engine", "PhysicsAsset", [MANNEQUIN]),
    ("PhysicsControl", "PhysicsControlAsset", ["/Game"]),          # ragdoll muscle setup
    ("PhysicsCore", "PhysicalMaterial", [MANNEQUIN]),
    ("Engine", "MirrorDataTable", [MANNEQUIN]),
    ("Engine", "CurveFloat", ["/Game"]),
    ("CoreUObject", "UserDefinedStruct", ["/Game"]),              # where 5.8 keeps most structs
    ("Engine", "UserDefinedStruct", ["/Game"]),
    ("Engine", "UserDefinedEnum", ["/Game"]),
    ("Engine", "AnimBlueprint", ["/Game"]),                       # anim graphs
    ("ControlRigDeveloper", "ControlRigBlueprint", ["/Game"]),    # foot placement and other rigs
    ("StateTreeModule", "StateTree", ["/Game"]),                  # NPC behaviour
    ("GameplayCameras", "CameraRigAsset", ["/Game"]),
    ("GameplayCameras", "CameraAsset", ["/Game"]),
    ("EnhancedInput", "InputAction", ["/Game"]),
    ("EnhancedInput", "InputMappingContext", ["/Game"]),
    ("SmartObjectsModule", "SmartObjectDefinition", ["/Game"]),
]

# Blueprints whose node graphs hold the sample's gameplay logic.
BLUEPRINT_ROOTS = ["/Game"]

reg = unreal.AssetRegistryHelpers.get_asset_registry()
written = []
counts = {}
errors = []


def find(module, cls, roots):
    f = unreal.ARFilter(class_paths=[unreal.TopLevelAssetPath("/Script/" + module, cls)],
                        package_paths=roots, recursive_paths=True)
    assets = sorted(reg.get_assets(f), key=lambda a: str(a.package_name))
    return assets[:LIMIT] if LIMIT else assets


def rel(package_name, root="/Game/"):
    p = str(package_name)
    return p[len(root):] if p.startswith(root) else p.lstrip("/")


def export(obj, path, exporter, options=None):
    os.makedirs(os.path.dirname(path), exist_ok=True)
    t = unreal.AssetExportTask()
    t.object = obj
    t.filename = path
    t.automated = True
    t.prompt = False
    t.replace_identical = True
    t.exporter = exporter
    if options:
        t.options = options
    ok = unreal.Exporter.run_asset_export_task(t)
    if ok:
        written.append(os.path.relpath(path, OUT).replace("\\", "/"))
    else:
        errors.append("export failed: " + path)
    return ok


def fbx_options():
    o = unreal.FbxExportOption()
    o.set_editor_property("collision", False)
    o.set_editor_property("export_morph_targets", False)
    o.set_editor_property("export_preview_mesh", False)
    o.set_editor_property("map_skeletal_motion_to_root", False)
    o.set_editor_property("bake_material_inputs", unreal.FbxMaterialBakeMode.DISABLED)
    return o


# Lines in a sequence dump that hold control-rig and editor-only data (about 1.6 MB per clip), not needed for the port.
SEQ_DROP = ("TransformParameterNamesAndCurves", "ScalarParameterNamesAndCurves", "ControlChannelMap",
            "PropertiesStates", "IsControlActive")


def export_t3d(obj, path, drop=()):
    """T3D export, re-saved as UTF-8 (Unreal writes UTF-16), optionally without lines that start with `drop`."""
    tmp = path + ".utf16"
    if not export(obj, tmp, unreal.ObjectExporterT3D()):
        return False
    written.pop()
    raw = open(tmp, "rb").read()
    text = raw.decode("utf-16") if raw[:2] in (b"\xff\xfe", b"\xfe\xff") else raw.decode("utf-8", "replace")
    if drop:
        text = "\n".join(l for l in text.splitlines() if not l.lstrip().startswith(drop))
    with open(path, "w", encoding="utf-8", newline="\n") as f:
        f.write(text)
    os.remove(tmp)
    written.append(os.path.relpath(path, OUT).replace("\\", "/"))
    return True


def sequence_info(seq):
    lib = unreal.AnimationLibrary
    n = lib.get_num_frames(seq)
    length = seq.get_editor_property("sequence_length")
    return {
        "length": length,
        "frames": n,
        "frame_rate": round(n / length, 4) if length else None,
        "root_motion": seq.get_editor_property("enable_root_motion"),
        "force_root_lock": seq.get_editor_property("force_root_lock"),
        "rate_scale": lib.get_rate_scale(seq),
    }


# 1. Animation sequences as FBX, plus their metadata.
sequences = {}
seqs = find("Engine", "AnimSequence", [ANIMS])
counts["AnimSequence"] = len(seqs)
opt = fbx_options()
for i, a in enumerate(seqs):
    seq = a.get_asset()
    r = rel(a.package_name, ANIMS + "/")
    if not SKIP_ANIMS:
        export(seq, os.path.join(OUT, "anims", r + ".fbx"), unreal.AnimSequenceExporterFBX(), opt)
    sequences[r] = sequence_info(seq)
    export_t3d(seq, os.path.join(OUT, "t3d", rel(a.package_name) + ".t3d"), SEQ_DROP)
    if i % 100 == 0:
        unreal.log("GASP anims %d / %d" % (i, len(seqs)))

# 2. The mannequin mesh, as glTF: the FBX skeletal mesh exporter in 5.8 always builds material baking data
# through a CPU-skinned component (FbxMaterialExportUtilities.cpp:674), which asserts in a headless editor.
mesh = unreal.load_asset(MESH)
if mesh:
    g = unreal.GLTFExportOptions()
    g.set_editor_property("bake_material_inputs", unreal.GLTFMaterialBakeMode.DISABLED)
    g.set_editor_property("export_level_sequences", False)
    g.set_editor_property("export_animation_sequences", False)
    path = os.path.join(OUT, "mesh", "SKM_UEFN_Mannequin.glb")
    os.makedirs(os.path.dirname(path), exist_ok=True)
    unreal.GLTFExporter.export_to_gltf(mesh, path, g, set())
    if os.path.exists(path):
        written.append("mesh/SKM_UEFN_Mannequin.glb")
    else:
        errors.append("mesh export failed")
else:
    errors.append("mannequin mesh not found at " + MESH)

# 3. Everything else as T3D.
for module, cls, roots in T3D_CLASSES:
    assets = find(module, cls, roots)
    counts[cls] = len(assets)
    for a in assets:
        export_t3d(a.get_asset(), os.path.join(OUT, "t3d", rel(a.package_name) + ".t3d"))

# 4. Blueprints. The class dump includes every event graph, function and macro with all their nodes.
bps = find("Engine", "Blueprint", BLUEPRINT_ROOTS)
counts["Blueprint"] = len(bps)
for a in bps:
    export_t3d(a.get_asset(), os.path.join(OUT, "t3d", rel(a.package_name) + ".t3d"))

with open(os.path.join(OUT, "sequences.json"), "w") as f:
    json.dump(sequences, f, indent=1)
written.append("sequences.json")

manifest = {
    "engine": unreal.SystemLibrary.get_engine_version(),
    "project": unreal.Paths.get_project_file_path(),
    "limit": LIMIT,
    "counts": counts,
    "errors": errors,
    "files": written,
}
with open(os.path.join(OUT, "manifest.json"), "w") as f:
    json.dump(manifest, f, indent=1)

# 5. Blueprint class defaults (Details-panel values the graph dumps leave out).
try:
    import sys
    sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
    import export_cdo
    export_cdo.run(OUT)
except Exception as e:
    unreal.log_error("GASP_CDO_FAIL %r" % e)

# 6. Clean JSON for the Godot side: data/*.json from the T3D dumps. t3d_to_json.py is plain Python and also runs
# standalone (python tools/unreal/t3d_to_json.py <extracted dir>).
try:
    import sys
    sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
    import t3d_to_json
    index = t3d_to_json.run(OUT, verbose=False)
    unreal.log("GASP_JSON %s" % json.dumps(index["counts"]))
    for w in index["warnings"]:
        unreal.log_warning("GASP_JSON_WARN " + w)
except Exception as e:
    unreal.log_error("GASP_JSON_FAIL %r" % e)

# 7. Foley: the sound waves as WAV (audio/) and the bank, MetaSound presets and mix as data (audio/foley_bank.json).
try:
    import sys
    sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
    import export_audio
    export_audio.run(OUT)
except Exception as e:
    unreal.log_error("GASP_AUDIO_FAIL %r" % e)

# 8. The retarget onto Manny: both reference poses, the retargeter's settings and the hand curve map (data/retarget.json).
try:
    import sys
    sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
    import export_retarget
    export_retarget.run(OUT)
except Exception as e:
    unreal.log_error("GASP_RETARGET_FAIL %r" % e)

unreal.log("GASP_DONE %s files, %s errors" % (len(written), len(errors)))
