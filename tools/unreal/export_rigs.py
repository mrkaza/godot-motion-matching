# Writes a readable listing of Control Rig graphs (every graph, collapse graph and library function):
# nodes with their unit / function / variable, input defaults, and links. For porting rigs by hand.
#   UnrealEditor-Cmd <GameAnimationSample.uproject> -run=pythonscript -script=<this file> -unattended -nop4 -nosplash -nullrhi
# Env: RIGS_OUT (folder, default extracted/rigs next to this repo), RIGS (comma-separated asset paths).
import os, unreal

HERE = os.path.dirname(os.path.abspath(__file__))
OUT = os.environ.get("RIGS_OUT") or os.path.join(HERE, "..", "..", "extracted", "rigs")
RIGS = (os.environ.get("RIGS") or
        "/Game/Blueprints/ControlRigs/CR_Biped_FootPlacement,"
        "/Game/Characters/UEFN_Mannequin/Rigs/CR_UEFN_Mannequin_FullBodyIK").split(",")


def call(obj, name, *args, default=None):
    f = getattr(obj, name, None)
    if f is None:
        return default
    try:
        return f(*args)
    except Exception:
        return default


def pin_lines(pin, depth, linked, out):
    path = call(pin, "get_pin_path") or ""
    direction = str(call(pin, "get_direction") or "")
    cpp = call(pin, "get_cpp_type") or ""
    subs = call(pin, "get_sub_pins") or []
    is_input = "INPUT" in direction.upper() or "IO" in direction.upper() or "VISIBLE" in direction.upper()
    dv = call(pin, "get_default_value") or ""
    mark = " <-linked" if path in linked else ""
    short = path.split(".", 1)[1] if "." in path else path
    if depth == 0 or not subs:
        if is_input and not subs:
            out.append(f"    {'  ' * depth}{short} [{cpp}] = {dv}{mark}")
        elif depth == 0:
            out.append(f"    {short} [{cpp}] ({direction.split('.')[-1]}){(' = ' + dv) if is_input and dv else ''}{mark}")
    if subs and (is_input and path not in linked):
        for s in subs:
            pin_lines(s, depth + 1, linked, out)


def node_desc(node):
    cls = node.get_class().get_name()
    title = call(node, "get_node_title") or ""
    extra = ""
    st = call(node, "get_script_struct")
    if st is not None:
        extra = st.get_name()
    for name in ("get_variable_name",):
        v = call(node, name)
        if v:
            extra += f" var={v}"
    ref = call(node, "get_referenced_function_header")
    if ref is not None:
        try:
            extra += f" fn={ref.get_editor_property('name')}"
        except Exception:
            pass
    return f"{node.get_name()} <{cls}> {extra} \"{title}\""


def dump_graph(g, out, seen):
    if g is None or g.get_path_name() in seen:
        return
    seen.add(g.get_path_name())
    out.append(f"\n=== GRAPH {g.get_path_name()}")
    for v in call(g, "get_local_variables") or []:
        out.append(f"  local {v.get_editor_property('name')} [{v.get_editor_property('cpp_type')}] = {v.get_editor_property('default_value')}")
    links = call(g, "get_links") or []
    linked = set()
    link_lines = []
    for l in links:
        s = call(l, "get_source_pin"); t = call(l, "get_target_pin")
        sp = call(s, "get_pin_path") if s else "?"; tp = call(t, "get_pin_path") if t else "?"
        linked.add(tp)
        link_lines.append(f"  {sp} -> {tp}")
    children = []
    for n in call(g, "get_nodes") or []:
        out.append("  " + node_desc(n))
        pl = []
        for p in call(n, "get_pins") or []:
            pin_lines(p, 0, linked, pl)
        out.extend(pl)
        cg = call(n, "get_contained_graph")
        if cg is not None:
            children.append(cg)
    out.append("  -- links")
    out.extend(link_lines)
    for cg in children:
        dump_graph(cg, out, seen)


os.makedirs(OUT, exist_ok=True)
for path in RIGS:
    bp = unreal.load_asset(path)
    if bp is None:
        unreal.log_error(f"export_rigs: cannot load {path}")
        continue
    out = [f"# {path}"]
    models = call(bp, "get_all_models") or []
    root = call(bp, "get_model")
    if root is not None:
        for v in call(root, "get_variable_descriptions") or []:
            out.append(f"var {v.get_editor_property('name')} [{v.get_editor_property('cpp_type')}] = {v.get_editor_property('default_value')}")
    lib = call(bp, "get_local_function_library")
    seen = set()
    for g in models:
        dump_graph(g, out, seen)
    if lib is not None:
        dump_graph(lib, out, seen)
        for n in call(lib, "get_nodes") or []:
            dump_graph(call(n, "get_contained_graph"), out, seen)
    name = path.rsplit("/", 1)[-1]
    with open(os.path.join(OUT, name + ".txt"), "w", encoding="utf-8") as f:
        f.write("\n".join(out))
    unreal.log(f"export_rigs: {name} {len(out)} lines")
