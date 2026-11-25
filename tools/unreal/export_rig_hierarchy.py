# Writes a Control Rig's hierarchy (bones, nulls, controls: parent, initial local/global transforms,
# control offsets) to extracted/rigs/<name>.hierarchy.txt. Run like export_rigs.py; env RIGS.
import os, unreal
HERE = os.path.dirname(os.path.abspath(__file__))
OUT = os.environ.get("RIGS_OUT") or os.path.join(HERE, "..", "..", "extracted", "rigs")
RIGS = (os.environ.get("RIGS") or "/Game/Blueprints/ControlRigs/CR_Biped_FootPlacement").split(",")

def t(x):
    r = x.rotation; p = x.translation
    return f"t=({p.x:.4f},{p.y:.4f},{p.z:.4f}) q=({r.x:.5f},{r.y:.5f},{r.z:.5f},{r.w:.5f})"

for path in RIGS:
    bp = unreal.load_asset(path)
    h = None
    for name in ("hierarchy",):
        try:
            h = bp.get_editor_property(name)
        except Exception as e:
            unreal.log_warning(f"no {name}: {e}")
    if h is None:
        h = bp.get_hierarchy_controller().get_hierarchy()
    out = []
    for k in h.get_all_keys(True):
        parents = h.get_parents(k)
        par = ",".join(f"{p.type.name}:{p.name}" for p in parents)
        line = f"{k.type.name}:{k.name} parent=[{par}] local {t(h.get_local_transform(k, True))} global {t(h.get_global_transform(k, True))}"
        if k.type == unreal.RigElementType.CONTROL:
            try:
                line += f" offset {t(h.get_control_offset_transform(k, unreal.RigControlTransformType.INITIAL))}"
            except Exception:
                pass
        out.append(line)
    name = path.rsplit("/", 1)[-1]
    with open(os.path.join(OUT, name + ".hierarchy.txt"), "w", encoding="utf-8") as f:
        f.write("\n".join(out))
    unreal.log(f"export_rig_hierarchy: {name} {len(out)}")
