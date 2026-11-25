# Exports the class defaults (CDO) of every blueprint in the sample: the Details-panel values the
# graph dumps leave out (movement speeds, capsule size, jump velocity, component settings...).
# Runs inside the Unreal editor, started like export_gasp.py with GASP_OUT set.
# Writes t3d/<blueprint path>.defaults.t3d (UTF-8).
import os, unreal

OUT = os.environ.get("GASP_OUT") or os.path.join(os.path.dirname(os.path.abspath(__file__)), "out")


def run(out):
    """Exports every blueprint's class defaults to <out>/t3d/<path>.defaults.t3d. Returns (done, failed)."""
    reg = unreal.AssetRegistryHelpers.get_asset_registry()
    done, failed = 0, []

    for cls in ("Blueprint", "AnimBlueprint", "ControlRigBlueprint"):
        module = "ControlRigDeveloper" if cls == "ControlRigBlueprint" else "Engine"
        f = unreal.ARFilter(class_paths=[unreal.TopLevelAssetPath("/Script/" + module, cls)], package_paths=["/Game"], recursive_paths=True)
        for a in sorted(reg.get_assets(f), key=lambda a: str(a.package_name)):
            name = str(a.package_name)
            try:
                bp = a.get_asset()
                cdo = unreal.get_default_object(bp.generated_class())
            except Exception as e:
                failed.append("%s: %r" % (name, e))
                continue
            path = os.path.join(out, "t3d", name[len("/Game/"):] + ".defaults.t3d")
            tmp = path + ".utf16"
            os.makedirs(os.path.dirname(path), exist_ok=True)
            t = unreal.AssetExportTask()
            t.object = cdo
            t.filename = tmp
            t.automated = True
            t.prompt = False
            t.replace_identical = True
            t.exporter = unreal.ObjectExporterT3D()
            if not unreal.Exporter.run_asset_export_task(t):
                failed.append(name + ": export failed")
                continue
            raw = open(tmp, "rb").read()
            text = raw.decode("utf-16") if raw[:2] in (b"\xff\xfe", b"\xfe\xff") else raw.decode("utf-8", "replace")
            with open(path, "w", encoding="utf-8", newline="\n") as fh:
                fh.write(text)
            os.remove(tmp)
            done += 1

    unreal.log("GASP_CDO_DONE %d exported, %d failed" % (done, len(failed)))
    for line in failed[:30]:
        unreal.log_warning("GASP_CDO_FAIL " + line)

    return done, failed


if __name__ == "__main__":
    run(OUT)
