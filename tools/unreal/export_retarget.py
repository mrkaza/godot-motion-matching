# Writes data/retarget.json: what the sample uses to put the UEFN mannequin's animation on Manny
# (BP_Manny: SKM_Manny_Simple with ABP_GenericRetarget and RTG_UEFN_to_UE5_Mannequin).
#   source_ref / target_ref   reference pose of each mesh, bone-local, Unreal space (cm, quaternion x y z w)
#   target_pose               the retargeter's target retarget pose ("Default Pose") offsets
#   ops                       the op stack settings the Godot side follows (scripts/motion/retarget.gd)
#   chains                    the IK rigs' retarget chains (start, end, IK goal)
#   curve_map                 ABP_GenericRetarget's chain -> curve map (UpdateRetargetProfile: the curve blends
#                             the chain's Blend to Source from the asset value to 1)
# Called from export_gasp.py (step 8). Also runs standalone in the editor's Python.
import json, os, re, tempfile, unreal

RTG = "/Game/Characters/UE5_Mannequins/Rigs/RTG_UEFN_to_UE5_Mannequin"
ABP = "/Game/Blueprints/RetargetedCharacters/ABP_GenericRetarget"
SOURCE_MESH = "/Game/Characters/UEFN_Mannequin/Meshes/SKM_UEFN_Mannequin"
TARGET_MESH = "/Game/Characters/UE5_Mannequins/Meshes/SKM_Manny_Simple"


def _t3d(path):
    obj = unreal.load_asset(path)
    fn = os.path.join(tempfile.gettempdir(), "gasp_retarget_%s.t3d" % path.split("/")[-1])
    t = unreal.AssetExportTask()
    t.object = obj
    t.filename = fn
    t.automated = True
    t.prompt = False
    t.replace_identical = True
    t.exporter = unreal.ObjectExporterT3D()
    if not unreal.Exporter.run_asset_export_task(t):
        raise RuntimeError("T3D export failed: " + path)
    b = open(fn, "rb").read()
    os.remove(fn)
    return (b.decode("utf-16") if b[:2] in (b"\xff\xfe", b"\xfe\xff") else b.decode("utf-8", "replace")).replace("\r", "")


def _ref_pose(mesh_path):
    mesh = unreal.load_asset(mesh_path)
    pose = unreal.AnimPoseExtensions.get_reference_pose(mesh.skeleton)
    out = {}
    for b in unreal.AnimPoseExtensions.get_bone_names(pose):
        t = unreal.AnimPoseExtensions.get_ref_bone_pose(pose, b, unreal.AnimPoseSpaces.LOCAL)
        q = t.rotation
        out[str(b)] = {"t": [t.translation.x, t.translation.y, t.translation.z], "q": [q.x, q.y, q.z, q.w]}
    return out


def _num(s):
    return float(s)


def _vec(s):
    m = re.match(r"\(X=([-\d.e]+),Y=([-\d.e]+),Z=([-\d.e]+)\)", s)
    return [_num(m.group(1)), _num(m.group(2)), _num(m.group(3))]


def _field(text, name, default=None):
    m = re.search(r"\b%s=(\([^()]*\)|\"[^\"]*\"|[^,()]+)" % re.escape(name), text)
    return m.group(1) if m else default


def _chain_entries(text, list_name):
    """The ((TargetChainName="X",k=v,...),(...)) list after list_name=, as dicts of raw strings."""
    i = text.find(list_name + "=(")
    if i < 0:
        return []
    i += len(list_name) + 2
    depth, j = 1, i
    while depth and j < len(text):
        depth += {"(": 1, ")": -1}.get(text[j], 0)
        j += 1
    body = text[i:j - 1]
    entries, depth, start = [], 0, None
    for k, ch in enumerate(body):
        if ch == "(":
            if depth == 0:
                start = k + 1
            depth += 1
        elif ch == ")":
            depth -= 1
            if depth == 0:
                entries.append(body[start:k])
    out = []
    for e in entries:
        d = {}
        for m in re.finditer(r"(\w+)=(\([^()]*\)|\"[^\"]*\"|[^,()]+)", e):
            d[m.group(1)] = m.group(2).strip('"')
        out.append(d)
    return out


def _ik_chains(ikrig_path):
    text = _t3d(ikrig_path)
    m = re.search(r"RetargetDefinition=\(RootBone=\"(\w+)\",PelvisBone=\"(\w+)\"", text)
    chains = {}
    for c in re.finditer(r"\(ChainName=\"(\w+)\",StartBone=\(BoneName=\"(\w+)\"\),EndBone=\(BoneName=\"(\w+)\"\)(?:,IKGoalName=\"(\w+)\")?", text):
        chains[c.group(1)] = {"start": c.group(2), "end": c.group(3), "goal": c.group(4) or ""}
    return {"pelvis": m.group(2) if m else "pelvis", "chains": chains}


def run(out_dir):
    rtg = _t3d(RTG)
    ops = {}
    for m in re.finditer(r"RetargetOps\((\d+)\)=/Script/IKRig\.(\w+)\((.*)\)\s*$", rtg, re.M):
        ops[m.group(2)] = m.group(3)
    pelvis = ops["IKRetargetPelvisMotionOp"]
    fk = ops["IKRetargetFKChainsOp"]
    bts = ops["IKRetargetBlendToSourceOp"]
    align = ops["IKRetargetAlignPoleVectorOp"]

    data = {
        "source_mesh": SOURCE_MESH,
        "target_mesh": TARGET_MESH,
        "source_ref": _ref_pose(SOURCE_MESH),
        "target_ref": _ref_pose(TARGET_MESH),
        "source_ikrig": _ik_chains(re.search(r"SourceIKRigAsset=\"[^']*'([^'.]+)", rtg).group(1)),
        "target_ikrig": _ik_chains(re.search(r"TargetIKRigAsset=\"[^']*'([^'.]+)", rtg).group(1)),
        "op_order": [re.search(r"Name=\"([^\"]+)\",ParentOpName", ops[k]).group(1) for k in ops],
    }
    # Target retarget pose (the only one; the source has none, so it is the reference pose).
    tp = re.search(r"TargetRetargetPoses=\(\(\"([^\"]+)\", \(RootTranslationOffset=(\([^)]*\)),BoneRotationOffsets=\((.*?)\)\)\)\)\)\)", rtg)
    rots = {}
    for r in re.finditer(r"\(\"(\w+)\", \(X=([-\d.e]+),Y=([-\d.e]+),Z=([-\d.e]+),W=([-\d.e]+)", tp.group(3)):
        rots[r.group(1)] = [_num(r.group(i)) for i in range(2, 6)]
    data["target_pose"] = {"name": tp.group(1), "root_offset": _vec(tp.group(2)), "rotations": rots}
    data["ops"] = {
        "pelvis": {
            "translation_offset_global": _vec(_field(pelvis, "TranslationOffsetGlobal")),
            "translation_offset_local": _vec(_field(pelvis, "TranslationOffsetLocal")),
            "blend_to_absolute_offset": _vec(_field(pelvis, "BlendToAbsoluteOffset")),
            "floor_constraint_weight": _num(_field(pelvis, "FloorConstraintWeight")),
            "blend_to_source_translation": _num(_field(pelvis, "BlendToSourceTranslation")),
            "scale_horizontal": _num(_field(pelvis, "ScaleHorizontal")),
            "scale_vertical": _num(_field(pelvis, "ScaleVertical")),
            "affect_ik_horizontal": _num(_field(pelvis, "AffectIKHorizontal")),
            "affect_ik_vertical": _num(_field(pelvis, "AffectIKVertical")),
            "rotation_alpha": _num(_field(pelvis, "RotationAlpha")),
            "translation_alpha": _num(_field(pelvis, "TranslationAlpha")),
        },
        "fk_chains": [{"target": c["TargetChainName"], "rotation_mode": c.get("RotationMode", "Interpolated"),
                       "translation_mode": c.get("TranslationMode", "None")} for c in _chain_entries(fk, "ChainsToRetarget")],
        "chain_map": {c["TargetChainName"]: c["SourceChainName"] for c in _chain_entries(fk, "ChainMap")},
        "blend_to_source": {c["TargetChainName"]: {"blend_to_source": _num(c.get("BlendToSource", 0)),
                                                   "translation_alpha": _num(c.get("TranslationAlpha", 1)),
                                                   "rotation_alpha": _num(c.get("RotationAlpha", 0)),
                                                   "apply_pelvis_offset": _num(c.get("ApplyPelvisOffset", 0))}
                            for c in _chain_entries(bts, "Chains")},
        "blend_to_source_alpha": _num(_field(bts, "Alpha", "1")),
        "align_pole": {c["TargetChainName"]: {"alpha": _num(c.get("AlignAlpha", 1)), "static_offset": _num(c.get("StaticAngularOffset", 0)),
                                              "maintain_offset": c.get("MaintainOffset", "False") == "True"}
                       for c in _chain_entries(align, "ChainsToAlign") if c.get("bEnabled") == "True"},
        "ik_chains": [c["TargetChainName"] for c in _chain_entries(ops["IKRetargetRunIKRigOp"], "Chains")],
    }
    abp = _t3d(ABP)
    m = re.search(r'VarName="ChainCurveMap".*?DefaultValue="(\(\(.*?\)\))"', abp, re.S)
    data["curve_map"] = {k: v for k, v in re.findall(r'\(\\"(\w+)\\", \\"(\w+)\\"\)', m.group(1))} if m else {}
    # The clips that carry those curves (from step 6's sequences.json; curve names are case-insensitive FNames).
    wanted = {v.lower() for v in data["curve_map"].values()}
    data["curves"] = {}
    seq_path = os.path.join(out_dir, "data", "sequences.json")
    if os.path.exists(seq_path):
        for name, seq in json.load(open(seq_path)).items():
            found = {c["name"].lower(): c for c in seq.get("curves", []) if c["name"].lower() in wanted}
            if found:
                data["curves"][name] = found
    os.makedirs(os.path.join(out_dir, "data"), exist_ok=True)
    with open(os.path.join(out_dir, "data", "retarget.json"), "w") as f:
        json.dump(data, f, indent=1)
    unreal.log("GASP_RETARGET %d source bones, %d target bones, %d fk chains" % (len(data["source_ref"]), len(data["target_ref"]), len(data["ops"]["fk_chains"])))


if __name__ == "__main__":
    run(os.environ.get("GASP_OUT") or os.path.join(os.path.dirname(os.path.abspath(__file__)), "out"))
