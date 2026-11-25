# Exports the sample's foley: the sound waves as WAV and what plays them as data.
# Runs inside the Unreal editor (headless), from export_gasp.py (step 7) or on its own:
#   UnrealEditor-Cmd <GameAnimationSample.uproject> -run=pythonscript -script=<this file> -unattended -nop4 -nosplash -nullrhi
# with GASP_OUT set to the Godot project's extracted/ folder.
#
# Writes:
#   audio/<folders under /Game/Audio>/<wave>.wav   every SoundWave a foley MetaSound plays (SoundExporterWAV: the
#                                                  imported PCM as it is)
#   t3d/Audio/...t3d                               UTF-8 dumps of the foley bank instance, every MetaSound source,
#                                                  the attenuation, submixes and the reverb preset (the blueprints
#                                                  are already dumped by export_gasp.py)
#   audio/foley_bank.json                          event tag -> MetaSound preset, and per preset: waves, Gain,
#                                                  Volume.Min/Max (dB), Pitch.Min/Max, source volume, submix send,
#                                                  No Repeats; plus attenuation, submixes and reverb settings
import json, os, sys, unreal

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
import t3d_to_json as T

OUT = os.environ.get("GASP_OUT") or os.path.join(os.path.dirname(os.path.abspath(__file__)), "out")
AUDIO_ROOT = "/Game/Audio"
BANK = "/Game/Audio/Foley/DefaultFoleyEventAudioBank"
ATTENUATION = "/Game/Audio/DefaultAttenuation"
# Classes dumped as text (MetaSound sources hold their whole graph in RootMetasoundDocument).
DUMP_CLASSES = ("MetaSoundSource", "SoundAttenuation", "SoundSubmix", "SubmixEffectReverbPreset", "DABP_FoleyAudioBank_C")


def _rel(package_name, root="/Game/"):
    p = str(package_name)
    return p[len(root):] if p.startswith(root) else p.lstrip("/")


def _task(obj, path, exporter):
    os.makedirs(os.path.dirname(path), exist_ok=True)
    t = unreal.AssetExportTask()
    t.object = obj
    t.filename = path
    t.automated = True
    t.prompt = False
    t.replace_identical = True
    t.exporter = exporter
    return unreal.Exporter.run_asset_export_task(t)


def _dump_t3d(obj, path):
    """T3D export re-saved as UTF-8 (Unreal writes UTF-16). Returns the text, or None."""
    tmp = path + ".utf16"
    if not _task(obj, tmp, unreal.ObjectExporterT3D()):
        return None
    raw = open(tmp, "rb").read()
    text = raw.decode("utf-16") if raw[:2] in (b"\xff\xfe", b"\xfe\xff") else raw.decode("utf-8", "replace")
    with open(path, "w", encoding="utf-8", newline="\n") as f:
        f.write(text)
    os.remove(tmp)
    return text


def _top_props(text):
    """Top-level properties of the first object in a T3D dump: {name: (line, raw value)}."""
    props = {}
    for i, line in enumerate(text.splitlines(), 1):
        if line.startswith("   ") and not line.startswith("    ") and "=" in line and not line.strip().startswith(("Begin ", "End ")):
            k, v = line.strip().split("=", 1)
            props.setdefault(k, (i, v))
    return props


def _asset_path(ref):
    """'/Script/Engine.SoundWave'/Game/A/B.B'' -> '/Game/A/B'."""
    s = str(ref)
    if "'" in s:
        s = s.split("'")[1]
    return s.split(".")[0]


def _literal(lit):
    if not isinstance(lit, dict):
        return lit
    for k, v in lit.items():
        if k.startswith("As"):
            if isinstance(v, list) and len(v) == 1 and not k.endswith(("Object", "UObject")) and lit.get("Type", "").find("Array") < 0:
                return v[0]
            return v
    return None


def _metasound(text):
    """A MetaSound source dump: graph input defaults, node literals, source settings (with T3D lines)."""
    props = _top_props(text)
    info = {"lines": {}}
    doc = None
    for k, (line, v) in props.items():
        if k == "RootMetasoundDocument":
            doc = T.parse_value(v)
            info["lines"]["RootMetasoundDocument"] = line
        elif k == "Volume":
            info["source_volume"] = float(v)
            info["lines"]["Volume"] = line
        elif k == "SoundSubmixObject":
            info["submix"] = _asset_path(v)
        elif k.startswith("SoundSubmixSends"):
            send = T.parse_value(v)
            info.setdefault("sends", []).append({"submix": _asset_path(send.get("SoundSubmix")), "level": float(send.get("SendLevel", 1.0))})
            info["lines"]["SoundSubmixSends"] = line
        elif k == "ReferencedAssetClassObjects":
            info["parent"] = _asset_path(T.parse_value(v)[0] if v.startswith("(") else v)
        elif k == "AttenuationSettings":
            info["attenuation"] = _asset_path(v)
    info.setdefault("source_volume", 1.0)   # USoundBase default
    if doc is None:
        return info
    inputs = {}
    for inp in doc.get("RootGraph", {}).get("Interface", {}).get("Inputs", []):
        defaults = inp.get("Defaults") or []
        inputs[inp["Name"]] = _literal(defaults[0].get("Literal")) if defaults else None
    info["inputs"] = inputs
    nodes = {}
    for g in doc.get("RootGraph", {}).get("PagedGraphs", []):
        for n in g.get("Nodes", []):
            names = {v["VertexID"]: v["Name"] for v in n.get("Interface", {}).get("Inputs", [])}
            lits = {names.get(l.get("VertexID"), l.get("VertexID")): _literal(l.get("Value")) for l in n.get("InputLiterals", [])}
            if lits:
                nodes.setdefault(n.get("Name"), []).append(lits)
    info["node_literals"] = nodes
    return info


def run(out):
    reg = unreal.AssetRegistryHelpers.get_asset_registry()
    assets = sorted(reg.get_assets_by_path(AUDIO_ROOT, recursive=True), key=lambda a: str(a.package_name))
    written, errors = [], []
    sounds = {}   # package -> metasound info
    texts = {}
    for a in assets:
        cls = str(a.asset_class_path.asset_name)
        if cls not in DUMP_CLASSES:
            continue
        path = os.path.join(out, "t3d", _rel(a.package_name) + ".t3d")
        text = _dump_t3d(a.get_asset(), path)
        if text is None:
            errors.append("t3d failed: %s" % a.package_name)
            continue
        written.append(os.path.relpath(path, out).replace("\\", "/"))
        texts[str(a.package_name)] = text
        if cls == "MetaSoundSource":
            sounds[str(a.package_name)] = _metasound(text)

    # Presets inherit any input they don't set from their parent.
    for pkg, info in sounds.items():
        parent = sounds.get(info.get("parent", ""), {})
        merged = dict(parent.get("inputs", {}))
        merged.update({k: v for k, v in info.get("inputs", {}).items() if v is not None})
        info["inputs"] = merged
        if not info.get("node_literals") and parent.get("node_literals"):
            info["node_literals"] = parent["node_literals"]

    # The bank: Assets map of gameplay tag -> sound.
    events = {}
    bank_text = texts.get(BANK, "")
    bank_line = 0
    for k, (line, v) in _top_props(bank_text).items():
        if k == "Assets":
            bank_line = line
            for pair in T.parse_value(v):
                tag, snd = pair[0], pair[1]
                events[tag.get("TagName") if isinstance(tag, dict) else str(tag)] = _asset_path(snd)
    if not events:
        errors.append("foley bank not found or empty: " + BANK)

    # Waves: every SoundWave a MetaSound plays, as WAV.
    wave_info = {}
    for info in sounds.values():
        for key, val in info.get("inputs", {}).items():
            if isinstance(val, list) and val and all("SoundWave" in str(x) for x in val):
                for ref in val:
                    wave_info.setdefault(_asset_path(ref), None)
    for pkg in sorted(wave_info):
        wave = unreal.load_asset(pkg)
        if wave is None:
            errors.append("wave not found: " + pkg)
            continue
        path = os.path.join(out, "audio", _rel(pkg, AUDIO_ROOT + "/") + ".wav")
        if _task(wave, path, unreal.SoundExporterWAV()):
            written.append(os.path.relpath(path, out).replace("\\", "/"))
            wave_info[pkg] = {
                "file": "audio/" + _rel(pkg, AUDIO_ROOT + "/") + ".wav",
                "duration": round(float(wave.get_editor_property("duration")), 5),
                "channels": int(wave.get_editor_property("num_channels")),
                "sample_rate": int(wave.get_editor_property("sample_rate")),
            }
        else:
            errors.append("wav export failed: " + pkg)

    def preset_json(pkg):
        info = sounds[pkg]
        ins = info.get("inputs", {})
        waves = []
        for key in ("Waves", "StartWaves", "LoopWaves"):
            for ref in ins.get(key) or []:
                w = wave_info.get(_asset_path(ref))
                if w:
                    waves.append(dict(w, input=key, asset=_asset_path(ref)))
        rnd = (info.get("node_literals", {}).get("Random Get") or [{}])[0]
        sends = info.get("sends", [])
        return {
            "asset": pkg, "parent": info.get("parent", ""),
            "t3d": "t3d/" + _rel(pkg) + ".t3d", "t3d_lines": info["lines"],
            "waves": waves,
            "gain": ins.get("Gain", 1.0),
            "volume_db": [ins.get("Volume.Min", 0.0), ins.get("Volume.Max", 0.0)],
            "pitch": [ins.get("Pitch.Min", 1.0), ins.get("Pitch.Max", 1.0)],
            "source_volume": info.get("source_volume", 1.0),
            "submix": info.get("submix", ""),
            "reverb_send": sends[0]["level"] if sends else 0.0,
            "no_repeats": rnd.get("No Repeats", 0),
            "shared_state": rnd.get("Enable Shared State", False),
            "other_inputs": {k: v for k, v in ins.items() if k not in ("Waves", "StartWaves", "LoopWaves", "Gain", "Volume.Min", "Volume.Max", "Pitch.Min", "Pitch.Max", "UE.Source.OnPlay")},
        }

    presets = {pkg.split("/")[-1]: preset_json(pkg) for pkg in sorted(sounds) if "/Presets/" in pkg}

    def props_of(pkg):
        return {k: T.parse_value(v) for k, (_, v) in _top_props(texts.get(pkg, "")).items()}

    att = props_of(ATTENUATION).get("Attenuation", {})
    submixes = {}
    reverb = {}
    for pkg in texts:
        p = props_of(pkg)
        if "/Mix/SM_" in pkg:
            submixes[pkg.split("/")[-1]] = {
                "parent": _asset_path(p.get("ParentSubmix", "")) if p.get("ParentSubmix") else "",
                "volume_db": float((p.get("OutputVolumeModulation") or {}).get("Value", 0.0)),
                "effects": [_asset_path(e) for k, e in p.items() if k.startswith("SubmixEffectChain")],
            }
        if "/Mix/Effects/" in pkg:
            reverb[pkg.split("/")[-1]] = p.get("Settings", {})
    data = {
        "bank": BANK, "bank_t3d": "t3d/" + _rel(BANK) + ".t3d", "bank_line": bank_line,
        "events": {tag: snd.split("/")[-1] for tag, snd in events.items()},
        "presets": presets,
        "attenuation": {"asset": ATTENUATION, "settings": att},
        "submixes": submixes,
        "reverb": reverb,
    }
    path = os.path.join(out, "audio", "foley_bank.json")
    os.makedirs(os.path.dirname(path), exist_ok=True)
    with open(path, "w", encoding="utf-8") as f:
        json.dump(data, f, indent=1)
    written.append("audio/foley_bank.json")
    unreal.log("GASP_AUDIO_DONE %d events, %d presets, %d waves, %d errors" % (len(events), len(presets), len([w for w in wave_info.values() if w]), len(errors)))
    for e in errors[:30]:
        unreal.log_warning("GASP_AUDIO_FAIL " + e)
    return written, errors


if __name__ == "__main__":
    run(OUT)
