# Converts the T3D dumps written by export_gasp.py into clean JSON for the Godot port.
#
#   python t3d_to_json.py <extracted dir>        (standalone; plain Python 3, stdlib only)
#   import t3d_to_json; t3d_to_json.run(OUT)     (called by export_gasp.py at the end of an export)
#
# Reads   <extracted>/t3d/**.t3d  (UTF-8, mirrors /Game)  and  <extracted>/sequences.json
# Writes  <extracted>/data/*.json  (see EMITTERS at the bottom; index.json lists counts and everything not converted)
#
# T3D only lists properties that differ from the C++ defaults (the class default object, or for array elements
# the default object's element at the same index, else the struct default). Every emitter below fills those
# defaults in, so the Godot side never needs to know them. Defaults come from the UE 5.8.4 headers
# (Engine/Plugins/Animation/PoseSearch, Engine/Plugins/Chooser, Engine/Source/Runtime/Engine);
# each table names its header.
import json, math, os, re, struct, sys
from collections import Counter, defaultdict

ANIMS_ROOT = "/Game/Characters/UEFN_Mannequin/Animations"


# ----------------------------------------------------------------------------------------------------------------
# 1. Generic T3D parser
# ----------------------------------------------------------------------------------------------------------------

class Arr:
    """An array property as T3D writes it: only the elements that differ from the default array's element at the
    same index, plus `Prop=` (array emptied) and `Prop.RemoveIndex(n)` (array shorter than the default)."""
    __slots__ = ("items", "removed", "cleared")

    def __init__(self):
        self.items, self.removed, self.cleared = {}, set(), False

    def merged(self, default=(), elem=None):
        """The real array: `default` (the default object's array) with the exported elements applied on top.
        `elem(index_value, default_value)` merges one exported element onto its default (struct deltas)."""
        base = [] if self.cleared else list(default)
        if self.removed:
            base = base[:min(self.removed)]
        n = max([len(base)] + [i + 1 for i in self.items])
        out = []
        for i in range(n):
            d = base[i] if i < len(base) else None
            if i in self.items:
                v = self.items[i]
                if isinstance(v, LazyValue):
                    v = self.items[i] = v.parse()
                out.append(elem(v, d) if elem else v)
            else:
                out.append(d)
        return out


class Obj:
    """One `Begin Object` block. Declaration and definition blocks with the same name are merged into one."""
    __slots__ = ("cls", "name", "export_path", "attrs", "props", "children", "parent", "custom", "used", "file")

    def __init__(self, name, parent=None):
        self.cls, self.name, self.export_path = None, name, None
        self.attrs, self.props, self.children = {}, {}, {}
        self.parent, self.custom, self.used, self.file = parent, [], set(), None

    @property
    def short_cls(self):
        """`/Script/PoseSearch.PoseSearchFeatureChannel_Position` -> `PoseSearchFeatureChannel_Position`."""
        c = self.cls or ""
        c = c.rsplit(".", 1)[-1]
        return c[:-2] if c.endswith("_C") and "/Game/" in (self.cls or "") else c

    @property
    def root(self):
        o = self
        while o.parent is not None:
            o = o.parent
        return o

    def has(self, name):
        return name in self.props

    def raw(self, name, default=None):
        """Parsed value of a property, marking it as consumed (index.json lists what nobody consumed)."""
        self.used.add(name)
        if name not in self.props:
            return default
        v = self.props[name]
        if isinstance(v, LazyValue):
            v = self.props[name] = v.parse()
        return v

    def get(self, name, default=None):
        """Scalar or struct property; struct values are merged onto a dict default."""
        v = self.raw(name, None)
        if v is None:
            return default
        if isinstance(default, dict) and isinstance(v, dict):
            return merge(default, v)
        return v

    def arr(self, name, default=(), elem=None):
        v = self.raw(name, None)
        if v is None:
            return list(default)
        if isinstance(v, Arr):
            return v.merged(default, elem)
        return [v]   # a single-element static array written without an index

    def child(self, name):
        return self.children.get(name)

    def find(self, name):
        """Resolve a sub-object name the way T3D writes references: this object, then each outer."""
        o = self
        while o is not None:
            if name in o.children:
                return o.children[name]
            if o.name == name:
                return o
            o = o.parent
        return None

    def walk(self):
        yield self
        for c in self.children.values():
            yield from c.walk()

    def unused(self):
        return [k for k in self.props if k not in self.used]


class LazyValue:
    """Property text parsed on first access (sequence dumps hold megabytes of curve data nobody reads)."""
    __slots__ = ("text",)

    def __init__(self, text):
        self.text = text

    def parse(self):
        return parse_value(self.text)


class T3DError(Exception):
    pass


_BEGIN = re.compile(r'^\s*Begin Object\b(.*)$')
_END = re.compile(r'^\s*End Object\s*$')
_ATTR = re.compile(r'(\w+)=("(?:[^"\\]|\\.)*"|\S+)')
_PROP = re.compile(r'^\s*([A-Za-z_][^=()"\']*?|"(?:[^"\\]|\\.)*")(?:\((\d+)\))?=(.*)$')
_REMOVE = re.compile(r'^\s*([A-Za-z_][\w]*)\.RemoveIndex\((\d+)\)\s*$')


def parse_file(path, eager=False):
    """Parse one .t3d file into its root objects (usually one)."""
    roots, stack, problems = [], [], []
    with open(path, encoding="utf-8-sig") as f:
        for lineno, line in enumerate(f, 1):
            line = line.rstrip("\r\n")
            if not line.strip():
                continue
            m = _BEGIN.match(line)
            if m:
                attrs = {k: unquote(v) for k, v in _ATTR.findall(m.group(1))}
                name = attrs.get("Name", "")
                parent = stack[-1] if stack else None
                siblings = parent.children if parent else {r.name: r for r in roots}
                o = siblings.get(name)
                if o is None:
                    o = Obj(name, parent)
                    o.file = path
                    if parent:
                        parent.children[name] = o
                    else:
                        roots.append(o)
                if "Class" in attrs:
                    o.cls = attrs["Class"]
                if "ExportPath" in attrs:
                    o.export_path = attrs["ExportPath"]
                o.attrs.update(attrs)
                stack.append(o)
                continue
            if _END.match(line):
                if not stack:
                    problems.append("%d: End Object without Begin" % lineno)
                else:
                    stack.pop()
                continue
            if not stack:
                problems.append("%d: text outside any object: %s" % (lineno, line[:80]))
                continue
            o = stack[-1]
            m = _REMOVE.match(line)
            if m:
                a = o.props.setdefault(m.group(1), Arr())
                if isinstance(a, Arr):
                    a.removed.add(int(m.group(2)))
                continue
            m = _PROP.match(line)
            if not m:
                o.custom.append(line.strip())   # e.g. blueprint "CustomProperties Pin (...)" lines
                continue
            name, idx, text = unquote(m.group(1)), m.group(2), m.group(3)
            val = LazyValue(text)
            if eager:
                val = val.parse()
            if idx is None:
                if text == "":
                    a = Arr()
                    a.cleared = True     # `Prop=`: an array emptied (or an object reference cleared)
                    o.props[name] = a
                else:
                    o.props[name] = val
            else:
                a = o.props.get(name)
                if not isinstance(a, Arr):
                    a = o.props[name] = Arr()
                a.items[int(idx)] = val
    if stack:
        problems.append("unterminated Begin Object: " + stack[-1].name)
    return roots, problems


# --- property values ---------------------------------------------------------------------------------------------

_KEY = re.compile(r'\s*([A-Za-z_][^=,()"\'\[]*?|"(?:[^"\\]|\\.)*")(?:\[(\d+)\]|\((\d+)\))?=(?!=)')
_STR = re.compile(r'"((?:[^"\\]|\\.)*)"')
_BARE = re.compile(r"(?:[^,()\"']|'[^']*')+")
_INT = re.compile(r'^[+-]?\d+$')
_FLOAT = re.compile(r'^[+-]?(?:\d+\.\d*|\.\d+|\d+)(?:[eE][+-]?\d+)?$')
_ESC = {"n": "\n", "r": "\r", "t": "\t", "\\": "\\", '"': '"', "'": "'"}


def unquote(s):
    if len(s) >= 2 and s[0] == '"' and s[-1] == '"':
        return re.sub(r'\\(.)', lambda m: _ESC.get(m.group(1), m.group(1)), s[1:-1])
    return s


def parse_value(text):
    v, i = _value(text, 0)
    rest = text[i:].strip()
    if rest:
        raise T3DError("trailing text after value: " + rest[:60])
    return v


def _value(s, i):
    n = len(s)
    while i < n and s[i] in " \t":
        i += 1
    if i >= n:
        return None, i
    c = s[i]
    if c == "(":
        return _paren(s, i)
    if c == '"':
        m = _STR.match(s, i)
        if not m:
            raise T3DError("unterminated string")
        return unquote(m.group(0)), m.end()
    m = _BARE.match(s, i)
    if not m:
        return None, i
    tok, j = m.group(0).strip(), m.end()
    if j < n and s[j] == "(":            # instanced struct: /Script/Chooser.AssetChooser(Asset=...)
        body, j = _paren(s, j)
        if isinstance(body, dict):
            body = dict(body)
        else:
            body = {"__items__": body}
        out = {"__type__": tok}
        out.update(body)
        return out, j
    return _scalar(tok), j


def _scalar(tok):
    if tok == "True":
        return True
    if tok == "False":
        return False
    if _INT.match(tok) and len(tok) < 19:
        return int(tok)
    if _FLOAT.match(tok):
        return float(tok)
    return tok


def _paren(s, i):
    """`(A=1,B=(C=2))` -> dict, `(1,2,3)` -> list, `()` -> {} (an all-defaults struct or an empty array)."""
    assert s[i] == "("
    i += 1
    keyed, items = {}, []
    n = len(s)
    while True:
        while i < n and s[i] in " \t":
            i += 1
        if i >= n:
            raise T3DError("unterminated (")
        if s[i] == ")":
            i += 1
            break
        m = _KEY.match(s, i)
        if m:
            key = unquote(m.group(1))
            idx = m.group(2) or m.group(3)
            v, i = _value(s, m.end())
            if idx is not None:
                a = keyed.get(key)
                if not isinstance(a, Arr):
                    a = keyed[key] = Arr()
                a.items[int(idx)] = v
            else:
                keyed[key] = v
        else:
            v, i = _value(s, i)
            items.append(v)
        while i < n and s[i] in " \t":
            i += 1
        if i < n and s[i] == ",":
            i += 1
        elif i < n and s[i] == ")":
            continue
        elif i >= n:
            raise T3DError("unterminated (")
        else:
            raise T3DError("unexpected %r in struct" % s[i])
    if keyed and items:
        keyed["__items__"] = items
        return keyed, i
    return (keyed if keyed or not items else items), i


# --- references --------------------------------------------------------------------------------------------------

_REF = re.compile(r"^(?:(/[\w/]+\.[\w]+|[A-Za-z_]\w*))?'(.*)'$")


def parse_ref(v):
    """`/Script/Engine.AnimSequence'/Game/A/B.B'` -> ("/Script/Engine.AnimSequence", "/Game/A/B.B"); None if not a ref."""
    if not isinstance(v, str):
        return None
    m = _REF.match(v.strip())
    if not m:
        return None
    return m.group(1) or "", m.group(2)


def ref_path(v):
    """Object path of a reference, or None for None/empty."""
    r = parse_ref(v)
    if r:
        return r[1]
    if isinstance(v, str) and v not in ("", "None") and v.startswith("/"):
        return v
    return None


def resolve(ctx, v):
    """A reference to a sub-object (by bare name, or `Asset:Sub.Sub`), resolved to its Obj; None if external."""
    p = ref_path(v)
    if p is None and isinstance(v, str) and v and v != "None":
        p = v
    if not p or p.startswith("/"):
        if p and ":" in p:                          # full path into the same package
            p = p.split(":", 1)[1]
            o = ctx.root
            for part in p.split("."):
                o = o.child(part) if o else None
            return o
        return None
    if ":" in p:
        head, tail = p.split(":", 1)
        o = ctx.root if ctx.root.name == head else None
        for part in tail.split("."):
            o = o.child(part) if o else None
        return o
    return ctx.find(p)


def asset_key(path):
    """`/Game/Characters/UEFN_Mannequin/Animations/Walk/M_X.M_X` -> `Walk/M_X` (the sequences.json / anims/ key).
    Assets outside Animations keep their /Game package path."""
    if path is None:
        return None
    if path.startswith("/Script/"):                 # native class / struct paths stay as they are
        return path
    p = path.split(":", 1)[0]
    if "." in p.rsplit("/", 1)[-1]:
        p = p.rsplit(".", 1)[0]
    if p.startswith(ANIMS_ROOT + "/"):
        return p[len(ANIMS_ROOT) + 1:]
    return p


def asset_name(path):
    return asset_key(path).rsplit("/", 1)[-1] if path else None


def short_class(cls):
    """`/Script/Engine.AnimSequence` -> `AnimSequence`; blueprint `..._C` classes keep the `_C`."""
    return cls.rsplit(".", 1)[-1] if cls else None


def merge(default, delta):
    """Struct delta onto its default (recursively for nested structs)."""
    if not isinstance(delta, dict):
        return delta
    out = dict(default) if isinstance(default, dict) else {}
    for k, v in delta.items():
        d = out.get(k)
        out[k] = merge(d, v) if isinstance(d, dict) and isinstance(v, dict) else v
    return out


def plain(v):
    """Parsed value -> JSON-friendly value (Arr -> list, sub-objects untouched)."""
    if isinstance(v, LazyValue):
        v = v.parse()
    if isinstance(v, Arr):
        return [plain(x) for x in v.merged()]
    if isinstance(v, dict):
        return {k: plain(x) for k, x in v.items()}
    if isinstance(v, list):
        return [plain(x) for x in v]
    if isinstance(v, float):
        return clean_float(v)
    return v


def clean_float(x):
    if isinstance(x, float) and (math.isnan(x) or math.isinf(x)):
        return str(x)
    return x


def as_list(v):
    if v is None:
        return []
    if isinstance(v, Arr):
        return v.merged()
    if isinstance(v, dict) and not v:
        return []
    if isinstance(v, dict) and "__items__" in v and len(v) == 1:
        return v["__items__"]
    if isinstance(v, list):
        return v
    return [v]


# ----------------------------------------------------------------------------------------------------------------
# 2. C++ enums (name -> numeric value), so JSON can carry both
# ----------------------------------------------------------------------------------------------------------------

def _seq(*names):
    return {n: i for i, n in enumerate(names)}


CPP_ENUMS = {
    # PoseSearch (PoseSearchSchema.h, PoseSearchDatabase.h, PoseSearchFeatureChannel*.h, PoseSearchFeatureVectorHelper.h)
    "EPoseSearchDataPreprocessor": _seq("None", "Normalize", "NormalizeOnlyByDeviation", "NormalizeWithCommonSchema"),
    "EPoseSearchMode": _seq("BruteForce", "PCAKDTree", "VPTree", "EventOnly"),
    "EPoseSearchMirrorOption": _seq("UnmirroredOnly", "MirroredOnly", "UnmirroredAndMirrored"),
    "EInputQueryPose": _seq("UseCharacterPose", "UseContinuingPose"),
    "EPermutationTimeType": _seq("UseSampleTime", "UsePermutationTime", "UseSampleToPermutationTime"),
    "EComponentStrippingVector": _seq("None", "StripXY", "StripZ"),
    "EHeadingAxis": _seq("X", "Y", "Z"),
    # Chooser (BoolColumn.h, EnumColumn.h, NameColumn.h, IHasContext.h, ChooserPropertyAccess.h)
    "EBoolColumnCellValue": {"MatchFalse": 0, "MatchTrue": 1, "MatchAny": 2},
    "EEnumColumnCellValueComparison": _seq("MatchEqual", "MatchNotEqual", "MatchAny"),
    "ENameColumnCellValueComparison": _seq("MatchEqual", "MatchNotEqual", "MatchAny"),
    "EObjectChooserResultType": _seq("ObjectResult", "ClassResult", "NoPrimaryResult"),
    "EContextObjectDirection": _seq("Read", "Write", "ReadWrite"),
    # Engine animation (AlphaBlend.h, AnimMontage.h, AnimLinkableElement.h, AnimTypes.h, BlendSpace.h, EngineTypes.h)
    "EAlphaBlendOption": _seq("Linear", "Cubic", "HermiteCubic", "Sinusoidal", "QuadraticInOut", "CubicInOut",
                              "QuarticInOut", "QuinticInOut", "CircularIn", "CircularOut", "CircularInOut", "ExpIn",
                              "ExpOut", "ExpInOut", "Custom"),
    "EMontageBlendMode": _seq("Standard", "Inertialization"),
    "EAnimLinkMethod": _seq("Absolute", "Relative", "Proportional"),
    "EMontageNotifyTickType": _seq("Queued", "BranchingPoint"),
    "ENotifyTriggerMode": _seq("AllAnimations", "HighestWeightedAnimation", "None"),
    "EFilterInterpolationType": _seq("BSIT_Average", "BSIT_Linear", "BSIT_Cubic", "BSIT_EaseInOut",
                                     "BSIT_ExponentialDecay", "BSIT_SpringDamper"),
    "EBlendSpaceAxis": _seq("BSA_None", "BSA_X", "BSA_Y"),
    "ERichCurveInterpMode": _seq("RCIM_Linear", "RCIM_Constant", "RCIM_Cubic", "RCIM_None"),
    "ERichCurveTangentMode": _seq("RCTM_Auto", "RCTM_User", "RCTM_Break", "RCTM_None", "RCTM_SmartAuto"),
    "ERichCurveTangentWeightMode": _seq("RCTWM_WeightedNone", "RCTWM_WeightedArrive", "RCTWM_WeightedLeave",
                                        "RCTWM_WeightedBoth"),
    "ERichCurveExtrapolation": _seq("RCCE_Cycle", "RCCE_CycleWithOffset", "RCCE_Oscillate", "RCCE_Linear",
                                    "RCCE_Constant", "RCCE_None"),
    "EMirrorFindReplaceMethod": _seq("Prefix", "Suffix", "RegularExpression"),
    "EAxis": _seq("None", "X", "Y", "Z"),
    # Physics (ConstraintTypes.h, ConstraintDrives.h, BodySetupEnums.h)
    "EAngularConstraintMotion": _seq("ACM_Free", "ACM_Limited", "ACM_Locked"),
    "ELinearConstraintMotion": _seq("LCM_Free", "LCM_Limited", "LCM_Locked"),
    "EAngularDriveMode": _seq("SLERP", "TwistAndSwing"),
    "ECollisionTraceFlag": _seq("CTF_UseDefault", "CTF_UseSimpleAndComplex", "CTF_UseSimpleAsComplex",
                                "CTF_UseComplexAsSimple"),
    "EPhysicsType": _seq("PhysType_Default", "PhysType_Kinematic", "PhysType_Simulated"),
    # MotionWarping (RootMotionModifier.h)
    "EMotionWarpRotationType": _seq("Default", "Facing", "OppositeDefault"),
    "EMotionWarpRotationMethod": _seq("Slerp", "SlerpWithClampedRate", "ConstantRate", "Scale"),
    "EWarpPointAnimProvider": _seq("None", "Static", "Bone"),
}


def enum(enum_name, value, ctx=None):
    """{"name": ..., "value": ...} for a C++ enum token (value None if the token is unknown)."""
    if isinstance(value, dict) and "name" in value and "value" in value:
        return value
    table = CPP_ENUMS[enum_name]
    if isinstance(value, int) and not isinstance(value, bool):
        names = [k for k, v in table.items() if v == value]
        return {"name": names[0] if names else None, "value": value}
    name = str(value).split("::")[-1]
    v = table.get(name)
    if v is None and ctx is not None:
        ctx.warn("unknown %s value %r" % (enum_name, value))
    return {"name": name, "value": v}


def f32(x):
    """Round to the float32 the engine actually stores (matters for %.2f labels)."""
    return struct.unpack("f", struct.pack("f", float(x)))[0]


def vec(v, default=(0.0, 0.0, 0.0)):
    v = v if isinstance(v, dict) else {}
    return [float(v.get(k, d)) for k, d in zip("XYZ", default)]


def rot(v):
    """FRotator as [Pitch, Yaw, Roll] in degrees."""
    v = v if isinstance(v, dict) else {}
    return [float(v.get("Pitch", 0.0)), float(v.get("Yaw", 0.0)), float(v.get("Roll", 0.0))]


def quat(v):
    v = v if isinstance(v, dict) else {}
    return [float(v.get("X", 0.0)), float(v.get("Y", 0.0)), float(v.get("Z", 0.0)), float(v.get("W", 1.0))]


def transform(v):
    v = v if isinstance(v, dict) else {}
    return {"translation": vec(v.get("Translation")), "rotation_xyzw": quat(v.get("Rotation")),
            "scale": vec(v.get("Scale3D"), (1.0, 1.0, 1.0))}


def interval(v, lo, hi):
    v = v if isinstance(v, dict) else {}
    return {"Min": float(v.get("Min", lo)), "Max": float(v.get("Max", hi))}


def name_or_none(v):
    if v in (None, "", "None"):
        return None
    return v


def bone_name(v):
    """FBoneReference `(BoneName="foot_l")` -> "foot_l" (None when unset)."""
    if isinstance(v, dict):
        return name_or_none(v.get("BoneName"))
    return name_or_none(v)


# ----------------------------------------------------------------------------------------------------------------
# 3. Conversion context: inputs, warnings and the "what was not converted" bookkeeping for index.json
# ----------------------------------------------------------------------------------------------------------------

# Properties / sub-object classes that are editor-only or cosmetic and deliberately not converted. They are still
# counted in index.json ("ignored"), separately from "unparsed" (present, not converted, not known to be irrelevant).
IGNORED_PROPS = {
    "*": {"AssetImportData", "ThumbnailInfo", "PreviewMesh", "PreviewSkeletalMesh", "PreviewBasePose", "DebugColor",
          "EditorColumnWidth", "EditorResultsColumnWidth", "AssetUserData", "DataModelInterface", "RawDataGuid",
          "BoneCompressionSettings", "CurveCompressionSettings", "VariableFrameStrippingSettings",
          "ImportFileFramerate", "ImportResampleFramerate", "Skeleton", "Guid", "NotifyColor", "TrackColor",
          "PlatformTargetFrameRate", "RetargetSourceAsset", "RetargetSourceAssetReferencePose",
          "bInjectAdditionalDebugChannels", "UniqueNameIndex", "UniqueNameId", "bMetaDataConverted"},
    "AnimSequence": {"RefFrameIndex"},
    "ChooserTable": {"NestedObjects", "Version", "CookedResults", "RootChooser"},
    "PhysicsAsset": {"EditorBodyFlags", "BoundsBodies"},
    "UserDefinedStruct": {"EditorData", "ScriptAndPropertyObjectReferences", "PropertyIDs"},
    "MirrorDataTable": {"RowStruct", "RowStructPathName"},
    "BlendSpace": {"BlendSpaceData", "bContainsRotationOffsetMeshSpaceSamples",
                   "bUseLegacySamplePointAnimationLengthCalculations", "SampleIndexWithMarkers", "DimensionIndices"},
    "BlendSpace1D": {"BlendSpaceData", "bContainsRotationOffsetMeshSpaceSamples",
                     "bUseLegacySamplePointAnimationLengthCalculations", "SampleIndexWithMarkers", "DimensionIndices"},
}
IGNORED_OBJECTS = {
    "AssetImportData", "InterchangeAssetImportData", "FbxAnimSequenceImportData", "AnimationModifiersAssetUserData",
    "AnimationSequencerDataModel", "AnimDataModel", "SceneThumbnailInfo", "UserDefinedStructEditorData",
}


class Context:
    def __init__(self, extracted):
        self.extracted = extracted
        self.t3d_dir = os.path.join(extracted, "t3d")
        self.out_dir = os.path.join(extracted, "data")
        self.warnings = []
        self.parse_problems = []
        self.unparsed_props = defaultdict(Counter)       # "AssetKind/ObjClass" -> prop -> count
        self.ignored_props = defaultdict(Counter)
        self.unconverted_objects = defaultdict(Counter)  # asset kind -> sub-object class -> count
        self.ignored_objects = Counter()
        self.files_by_class = defaultdict(list)          # root class (short) -> [file]
        self.blueprints = {}                             # generated class path "/Game/X/BP.BP_C" -> info
        self.enum_values = defaultdict(dict)             # enum path key -> {"NewEnumerator0": 0}
        self.enum_value_sources = defaultdict(set)
        self.enums, self.enum_display = {}, {}            # filled by load_enums
        self.cdo_files, self._cdo = {}, {}               # blueprint generated class -> .defaults.t3d (class defaults)

    def cdo(self, cls):
        """Class default object of a blueprint class (from <blueprint>.defaults.t3d), or None if not exported."""
        if cls not in self._cdo:
            path = self.cdo_files.get(cls)
            roots = self.parse(path) if path else []
            self._cdo[cls] = roots[0] if roots else None
        return self._cdo[cls]

    def warn(self, msg):
        self.warnings.append(msg)

    def rel(self, path):
        return os.path.relpath(path, self.t3d_dir).replace("\\", "/")

    def parse(self, path):
        roots, problems = parse_file(path)
        for p in problems:
            self.parse_problems.append("%s: %s" % (self.rel(path), p))
        return roots

    def account(self, kind, root, seen=()):
        """Record, for one converted asset, every property nobody consumed and every sub-object nobody visited."""
        for o in root.walk():
            cls = o.short_cls or "?"
            if not o.used and o not in seen:
                if cls in IGNORED_OBJECTS or _ignored_ancestor(o):
                    self.ignored_objects[cls] += 1
                else:
                    self.unconverted_objects[kind][cls] += 1
                continue
            ign = IGNORED_PROPS["*"] | IGNORED_PROPS.get(cls, set()) | IGNORED_PROPS.get(kind, set())
            key = "%s/%s" % (kind, cls)
            for k in o.unused():
                (self.ignored_props if k in ign else self.unparsed_props)[key][k] += 1
            if o.custom:
                self.unparsed_props[key]["<custom lines>"] += len(o.custom)


def _ignored_ancestor(o):
    p = o.parent
    while p is not None:
        if p.short_cls in IGNORED_OBJECTS:
            return True
        p = p.parent
    return False


class Layered:
    """An object seen through its archetype chain: the instance, then its blueprint class defaults (CDO, from the
    .defaults.t3d dumps), then the parent blueprint's. Each layer only lists what differs from the next one."""

    def __init__(self, layers):
        self.layers = [l for l in layers if l is not None]
        self.o = self.layers[0] if self.layers else None

    def __getattr__(self, name):          # name, cls, children, parent, short_cls, used, custom ...
        return getattr(self.o, name)

    def has(self, name):
        return any(l.has(name) for l in self.layers)

    def raw(self, name, default=None):
        v, found = None, False
        for l in reversed(self.layers):    # deepest first, nearest last
            if l.has(name):
                x = l.raw(name)
                if isinstance(x, Arr):
                    x = x.merged(as_list(v) if found else [], lambda a, d: merge(d, a) if isinstance(d, dict) else a)
                elif isinstance(x, dict) and isinstance(v, dict):
                    x = merge(v, x)
                v, found = x, True
        return v if found else default

    def get(self, name, default=None):
        v = self.raw(name)
        if v is None:
            return default
        if isinstance(default, dict) and isinstance(v, dict):
            return merge(default, v)
        return v

    def arr(self, name, default=(), elem=None):
        base = list(default)
        for l in reversed(self.layers):
            if l.has(name):
                x = l.raw(name)
                base = x.merged(base, elem) if isinstance(x, Arr) else [x]
        return base

    def prop_names(self):
        names = []
        for l in self.layers:
            names += [k for k in l.props if k not in names]
        return names

    def child_view(self, name):
        return Layered([l.child(name) for l in self.layers])


def layered(o, ctx):
    """Layered view of an object: its archetype chain through blueprint class defaults. Sub-objects of a blueprint
    instance take the same-named sub-object of the class defaults as archetype."""
    if o is None:
        return None
    if o.parent is not None and o.parent.cls and o.parent.cls.startswith("/Game/"):
        return layered(o.parent, ctx).child_view(o.name)
    layers, cls, n = [o], o.cls, 0
    while cls and cls.startswith("/Game/") and n < 10:
        cdo = ctx.cdo(cls)
        if cdo is not None:
            layers.append(cdo)
        cls = ctx.blueprints.get(cls, {}).get("parent")
        n += 1
    return Layered(layers)


def friendly(name):
    """User-defined struct member `StartTime_6_43E5D7A74934F395460447B8CF09CCD0` -> `StartTime`."""
    if not isinstance(name, str):
        return name
    return re.sub(r"_\d+_[0-9A-F]{32}$", "", name)


def obj_json(o, seen, depth=0):
    """Generic conversion of an object: its non-default properties, with references to its own sub-objects inlined.
    Used for objects whose defaults live in blueprint class data that T3D does not include."""
    seen.add(o)
    out = {"class": o.short_cls, "class_path": o.cls}
    for k in list(o.props):
        out[k] = _inline(o.raw(k), o, seen, depth)
    if o.custom:
        out["custom_lines"] = list(o.custom)
    return out


def _inline(v, owner, seen, depth):
    v = plain(v)
    if isinstance(v, str):
        sub = resolve(owner, v) if v and v != "None" and (parse_ref(v) or v in owner.children) else None
        if sub is not None and sub is not owner and depth < 8 and _is_descendant(sub, owner):
            return obj_json(sub, seen, depth + 1)
        return v
    if isinstance(v, list):
        return [_inline(x, owner, seen, depth) for x in v]
    if isinstance(v, dict):
        return {k: _inline(x, owner, seen, depth) for k, x in v.items()}
    return v


def _is_descendant(o, ancestor):
    p = o.parent
    while p is not None:
        if p is ancestor:
            return True
        p = p.parent
    return False


# ----------------------------------------------------------------------------------------------------------------
# 4. Pose search schemas
# ----------------------------------------------------------------------------------------------------------------

ROOT_BONE = "root"   # reference skeleton bone 0 of SK_UEFN_Mannequin (the skeleton itself is not in the T3D dump)

SCHEMA_DEFAULTS = {  # PoseSearchSchema.h:73-120
    "SampleRate": 30, "DataPreprocessor": "Normalize", "NumberOfPermutations": 1, "PermutationsSampleRate": 30,
    "PermutationsTimeOffset": 0.0, "bAddDataPadding": False, "bInjectAdditionalDebugChannels": False,
}

_BONE_CHANNEL = {"bDefaultWithRootBone": True, "Bone": None, "SampleRole": None, "OriginBone": None,
                 "OriginRole": None, "Weight": 1.0, "SampleTimeOffset": 0.0, "OriginTimeOffset": 0.0,
                 "InputQueryPose": "UseContinuingPose", "PermutationTimeType": "UseSampleTime",
                 "NormalizationGroup": None}
CHANNEL_DEFAULTS = {  # PoseSearchFeatureChannel_<Kind>.h (and the constructors in the matching .cpp)
    "Position": dict(_BONE_CHANNEL, ComponentStripping="None", bNormalizeDisplacement=False),
    "Velocity": dict(_BONE_CHANNEL, ComponentStripping="None", bUseCharacterSpaceVelocities=True, bNormalize=False),
    "Heading": dict(_BONE_CHANNEL, ComponentStripping="None", HeadingAxis="X"),
    "Distance": dict(_BONE_CHANNEL, MaxDistance=0.0),
    "Phase": {"Bone": None, "SampleRole": None, "Weight": 1.0, "InputQueryPose": "UseContinuingPose",
              "NormalizationGroup": None},
    "Curve": {"CurveName": None, "SampleRole": None, "Weight": 1.0, "SampleTimeOffset": 0.0,
              "InputQueryPose": "UseContinuingPose", "NormalizationGroup": None},
    "FilterCrashingLegs": {"LeftThigh": None, "RightThigh": None, "LeftFoot": None, "RightFoot": None,
                           "SampleRole": None, "Weight": 0.2, "InputQueryPose": "UseContinuingPose",
                           "AllowedTolerance": 0.3},
    "Padding": {"PaddingSize": 1},
    "PermutationTime": {"Weight": 1.0},
    "SamplingTime": {"Weight": 0.0, "TimeToMatch": 0.0},
    "TimeToEvent": {"Weight": 0.0, "SamplingAttributeId": 0},
    "Group": {"SampleRole": None, "DebugWeightGroupID": -1},
    "Trajectory": {"SampleRole": None, "DebugWeightGroupID": -1, "Weight": 7.0},     # Weight = 7 in the constructor
    "Pose": {"SampleRole": None, "DebugWeightGroupID": -1, "Weight": 1.0, "InputQueryPose": "UseContinuingPose",
             "bUseCharacterSpaceVelocities": True, "PermutationTimeType": "UseSampleTime"},
}
BONE_PROPS = {"Bone", "OriginBone", "LeftThigh", "RightThigh", "LeftFoot", "RightFoot"}
CHANNEL_ENUMS = {"InputQueryPose": "EInputQueryPose", "PermutationTimeType": "EPermutationTimeType",
                 "ComponentStripping": "EComponentStrippingVector", "HeadingAxis": "EHeadingAxis"}
CARD = {"None": 3, "StripXY": 1, "StripZ": 2}

# Trajectory and Pose channels expand into these leaves (PoseSearchFeatureChannel_Trajectory.cpp:49-137, _Pose.cpp:36-133)
TRAJ_FLAGS = {"Velocity": 1, "Position": 2, "VelocityDirection": 4, "FacingDirection": 8, "VelocityXY": 16,
              "PositionXY": 32, "VelocityDirectionXY": 64, "FacingDirectionXY": 128}
TRAJ_DEFAULT_SAMPLES = [  # constructor, Trajectory.cpp:24-46
    {"Offset": -0.4, "Flags": 32, "Weight": 0.4, "NormalizationGroup": None},
    {"Offset": 0.0, "Flags": 16 | 128, "Weight": 2.0, "NormalizationGroup": None},
    {"Offset": 0.35, "Flags": 32 | 128, "Weight": 0.7, "NormalizationGroup": None},
    {"Offset": 0.7, "Flags": 16 | 32 | 128, "Weight": 0.5, "NormalizationGroup": None},
]
TRAJ_SAMPLE_DEFAULT = {"Offset": 0.0, "Flags": 2, "Weight": 1.0, "NormalizationGroup": None}
POSE_FLAGS = {"Velocity": 1, "Position": 2, "Rotation": 4, "Phase": 8}
POSE_DEFAULT_BONES = [  # constructor, Pose.cpp:16-34
    {"Reference": {"BoneName": "foot_l"}, "Flags": 3, "NormalizationGroup": None, "Weight": 1.0},
    {"Reference": {"BoneName": "foot_r"}, "Flags": 3, "NormalizationGroup": None, "Weight": 1.0},
]
POSE_BONE_DEFAULT = {"Reference": {"BoneName": None}, "Flags": 2, "NormalizationGroup": None, "Weight": 1.0}


def channel_kind(o, ctx):
    """`PoseSearchFeatureChannel_Position` -> "Position"; blueprint channels report their C++ parent's kind."""
    cls = o.cls or ""
    bp = None
    if cls.startswith("/Game/"):
        bp = cls
        cls = ctx.blueprints.get(cls, {}).get("parent") or ""
        if not cls:
            ctx.warn("blueprint channel %s: parent class unknown" % bp)
    short = short_class(cls) or ""
    if short.startswith("PoseSearchFeatureChannel_"):
        return short[len("PoseSearchFeatureChannel_"):], bp
    return short, bp


def read_channel(o, kind):
    """Channel properties with defaults filled (raw tokens; enums converted later)."""
    d = dict(CHANNEL_DEFAULTS.get(kind, {}))
    for k in list(d):
        if o.has(k):
            v = o.raw(k)
            d[k] = bone_name(v) if k in BONE_PROPS else (name_or_none(v) if k.endswith("Role") or k in (
                "NormalizationGroup", "CurveName") else v)
    o.raw("DebugColor")
    return d


class SchemaBuilder:
    """Mirrors UPoseSearchSchema::Finalize: leaves in order, offsets, bone references, labels."""

    def __init__(self, ctx, schema_name, roles):
        self.ctx, self.schema_name = ctx, schema_name
        self.card = 0
        self.leaves = []
        self.bones = {r: [ROOT_BONE] for r in roles}

    def add_bone(self, bone, role, default_root=True):
        if role not in self.bones:
            self.ctx.warn("%s: role %r not in Skeletons" % (self.schema_name, role))
            return -2
        if bone is None:
            if not default_root:
                return -1                       # TrajectorySchemaBoneIdx
            bone = ROOT_BONE
        refs = self.bones[role]
        if bone not in refs:
            refs.append(bone)
        return refs.index(bone)

    def add_leaf(self, kind, p, outer_label, path, extra=None):
        # cardinality per leaf Finalize(): vectors 3/2/1 by stripping, Phase 2, Padding N, everything else 1
        if kind in ("Position", "Velocity", "Heading"):
            n = CARD[p["ComponentStripping"]]
        else:
            n = {"Phase": 2, "Padding": p.get("PaddingSize", 1)}.get(kind, 1)
        leaf = {"index": len(self.leaves), "type": kind, "path": path, "offset": self.card, "cardinality": n}
        self.card += n
        role = p.get("SampleRole")
        for b in ("Bone", "OriginBone"):     # AddBoneReference, in the order Finalize() calls it
            if b in p:
                origin = b == "OriginBone"
                idx = self.add_bone(p[b], p.get("OriginRole") if origin else role, p.get("bDefaultWithRootBone", True))
                leaf["origin_bone" if origin else "bone"] = p[b] if p[b] else (ROOT_BONE if idx >= 0 else None)
                leaf["origin_bone_index" if origin else "bone_index"] = idx
        for b in ("LeftThigh", "RightThigh", "LeftFoot", "RightFoot"):
            if b in p:
                leaf[b] = p[b]
                leaf[b + "_index"] = self.add_bone(p[b], role)
        for k, v in p.items():
            if k in BONE_PROPS:
                continue
            leaf[k] = enum(CHANNEL_ENUMS[k], v, self.ctx) if k in CHANNEL_ENUMS else v
        if extra:
            leaf.update(extra)
        leaf["label"] = self.label(kind, p, leaf, outer_label)
        self.leaves.append(leaf)
        return leaf

    def label(self, kind, p, leaf, outer):
        """FeatureChannel GetLabel (Full_Horizontal), used by CanBeNormalizedWith to pair channels for normalization."""
        def bone_part(idx_key, bone_key, role):
            s = ""
            idx = leaf.get(idx_key, 0)
            if idx > 0:
                s += "_" + leaf[bone_key]
            elif idx == -1:
                s += "_Trj"
            if role:
                s += "[%s]" % role
            return s

        def tail():
            s = ""
            pt = p.get("PermutationTimeType", "UseSampleTime")
            s += {"UsePermutationTime": "_PT", "UseSampleToPermutationTime": "_SPT"}.get(pt, "")
            s += " %.2f" % f32(p.get("SampleTimeOffset", 0.0))
            o = f32(p.get("OriginTimeOffset", 0.0))
            if abs(o) > 1e-8:
                s += "-%.2f" % o
            return s

        strip = {"StripXY": "_z", "StripZ": "_xy"}.get(p.get("ComponentStripping"), "")
        if kind in ("Position", "Velocity", "Heading", "Distance"):
            head = {"Position": "Pos" + ("_ND" if p.get("bNormalizeDisplacement") else ""),
                    "Velocity": "Vel" + ("Dir" if p.get("bNormalize") else ""),
                    "Heading": "Head" + str(p.get("HeadingAxis", "X")),
                    "Distance": "Dist"}[kind]
            if kind != "Distance":
                head += strip
            core = head + bone_part("bone_index", "bone", p.get("SampleRole")) + \
                bone_part("origin_bone_index", "origin_bone", p.get("OriginRole")) + tail()
        elif kind == "Phase":
            core = "Pha" + ("_" + leaf["bone"] if leaf.get("bone_index", 0) > 0 else "")
        elif kind == "Curve":
            core = "Curve_%s %.2f" % (p.get("CurveName") or "None", f32(p.get("SampleTimeOffset", 0.0)))
        elif kind == "Padding":
            core = "Pad_%d_%d" % (leaf["offset"], leaf["offset"] + leaf["cardinality"])
        elif kind == "PermutationTime":
            core = "PermTime"
        elif kind == "SamplingTime":
            core = "SamplTime"
        elif kind == "TimeToEvent":
            core = "TimeToEvent_%d" % p.get("SamplingAttributeId", 0)
        else:
            core = leaf.get("object_name") or kind    # base GetLabel: the object name
        return (outer + "_" if outer else "") + core


def group_label(outer, word, p):
    s = word
    if p.get("SampleRole"):
        s += "[%s]" % p["SampleRole"]
    if word == "Pose":
        s += {"UsePermutationTime": "_PT", "UseSampleToPermutationTime": "_SPT"}.get(p.get("PermutationTimeType"), "")
    if p.get("DebugWeightGroupID", -1) != -1:
        s += "_%d" % p["DebugWeightGroupID"]
    return (outer + "_" if outer else "") + s


def expand_channel(o, sb, ctx, outer_label, path, tree_out):
    """Walk one channel object (recursively through Group/Trajectory/Pose) adding its leaves to the builder."""
    kind, bp = channel_kind(o, ctx)
    p = read_channel(layered(o, ctx) if bp else o, kind)
    node = {"type": kind, "object": o.name}
    if bp:
        node["blueprint_class"] = asset_key(bp)
        node["blueprint_functions"] = ctx.blueprints.get(bp, {}).get("functions", [])
    first = len(sb.leaves)
    if kind == "Group":
        node["SampleRole"] = p["SampleRole"]
        label = group_label(outer_label, "Group", p)
        node["children"] = []
        for i, ref in enumerate(o.arr("SubChannels")):
            sub = resolve(o, ref)
            if sub is None:
                if name_or_none(ref):
                    ctx.warn("%s: sub-channel %r not found" % (sb.schema_name, ref))
                continue
            expand_channel(sub, sb, ctx, label, "%s/%s" % (path, sub.name), node["children"])
    elif kind == "Trajectory":
        node.update(Weight=p["Weight"], SampleRole=p["SampleRole"])
        label = group_label(outer_label, "Traj", p)
        samples = o.arr("Samples", TRAJ_DEFAULT_SAMPLES, lambda v, d: merge(d or TRAJ_SAMPLE_DEFAULT, v))
        node["samples"] = []
        for si, s in enumerate(samples):
            flags = int(s.get("Flags", 2))
            node["samples"].append({"Offset": s["Offset"], "Flags": flags, "Weight": s["Weight"],
                                    "NormalizationGroup": name_or_none(s.get("NormalizationGroup")),
                                    "flag_names": [k for k, v in TRAJ_FLAGS.items() if flags & v]})
            for kind2, plain_flag, xy_flag, overrides in (
                    ("Position", "Position", "PositionXY", {}),
                    ("Velocity", "Velocity", "VelocityXY", {"bUseCharacterSpaceVelocities": False}),
                    ("Velocity", "VelocityDirection", "VelocityDirectionXY",
                     {"bUseCharacterSpaceVelocities": False, "bNormalize": True}),
                    ("Heading", "FacingDirection", "FacingDirectionXY", {})):
                if not flags & (TRAJ_FLAGS[plain_flag] | TRAJ_FLAGS[xy_flag]):
                    continue
                q = dict(CHANNEL_DEFAULTS[kind2])
                q.update(overrides)
                q.update(SampleRole=p["SampleRole"], OriginRole=p["SampleRole"], SampleTimeOffset=s["Offset"],
                         Weight=float(s["Weight"]) * float(p["Weight"]),
                         NormalizationGroup=name_or_none(s.get("NormalizationGroup")),
                         InputQueryPose="UseCharacterPose")
                if flags & TRAJ_FLAGS[xy_flag]:
                    q["ComponentStripping"] = "StripZ"
                sb.add_leaf(kind2, q, label, "%s/Samples(%d)/%s" % (path, si, kind2 if plain_flag == kind2 else plain_flag),
                            {"expanded_from": {"channel": "Trajectory", "sample": si,
                                               "flag": xy_flag if flags & TRAJ_FLAGS[xy_flag] else plain_flag,
                                               "sample_weight": s["Weight"], "parent_weight": p["Weight"]}})
        check_expanded(o, sb.leaves[first:], sb, ctx)
    elif kind == "Pose":
        node.update({k: p[k] for k in ("Weight", "SampleRole", "InputQueryPose", "bUseCharacterSpaceVelocities",
                                       "PermutationTimeType")})
        node["InputQueryPose"] = enum("EInputQueryPose", p["InputQueryPose"])
        node["PermutationTimeType"] = enum("EPermutationTimeType", p["PermutationTimeType"])
        label = group_label(outer_label, "Pose", p)
        bones = o.arr("SampledBones", POSE_DEFAULT_BONES, lambda v, d: merge(d or POSE_BONE_DEFAULT, v))
        node["bones"] = []
        for bi, b in enumerate(bones):
            flags, bname = int(b.get("Flags", 2)), bone_name(b.get("Reference"))
            node["bones"].append({"bone": bname, "Flags": flags, "Weight": b["Weight"],
                                  "NormalizationGroup": name_or_none(b.get("NormalizationGroup")),
                                  "flag_names": [k for k, v in POSE_FLAGS.items() if flags & v]})
            common = dict(SampleRole=p["SampleRole"], Weight=float(b["Weight"]) * float(p["Weight"]),
                          NormalizationGroup=name_or_none(b.get("NormalizationGroup")),
                          InputQueryPose=p["InputQueryPose"])
            src = {"channel": "Pose", "bone": bi, "sample_weight": b["Weight"], "parent_weight": p["Weight"]}
            todo = []
            if flags & POSE_FLAGS["Position"]:
                todo.append(("Position", {"PermutationTimeType": p["PermutationTimeType"], "OriginRole": p["SampleRole"]}, "Position"))
            if flags & POSE_FLAGS["Rotation"]:
                for axis in ("X", "Y"):
                    todo.append(("Heading", {"HeadingAxis": axis, "PermutationTimeType": p["PermutationTimeType"],
                                             "OriginRole": p["SampleRole"]}, "Rotation"))
            if flags & POSE_FLAGS["Velocity"]:
                todo.append(("Velocity", {"bUseCharacterSpaceVelocities": p["bUseCharacterSpaceVelocities"],
                                          "PermutationTimeType": p["PermutationTimeType"],
                                          "OriginRole": p["SampleRole"]}, "Velocity"))
            if flags & POSE_FLAGS["Phase"]:
                todo.append(("Phase", {}, "Phase"))
            for kind2, over, flag in todo:
                q = dict(CHANNEL_DEFAULTS[kind2])
                q.update(common)
                q.update(over)
                q["Bone"] = bname
                sb.add_leaf(kind2, q, label, "%s/SampledBones(%d)/%s" % (path, bi, flag),
                            {"expanded_from": dict(src, flag=flag)})
        check_expanded(o, sb.leaves[first:], sb, ctx)
    else:
        if kind not in CHANNEL_DEFAULTS:
            ctx.warn("%s: unknown channel class %s (%s)" % (sb.schema_name, o.cls, o.name))
        filters = [plain(f) for f in o.arr("Filters")]
        extra = {"object_name": o.name, "class": short_class(o.cls)}
        if bp:
            extra["blueprint_class"] = asset_key(bp)
            extra["blueprint_functions"] = ctx.blueprints.get(bp, {}).get("functions", [])
            extra["blueprint_defaults_found"] = ctx.cdo(bp) is not None
        if filters:
            extra["filters"] = filters
        sb.add_leaf(kind, p, outer_label, path, extra)
    node["leaves"] = list(range(first, len(sb.leaves)))
    tree_out.append(node)


def check_expanded(o, leaves, sb, ctx):
    """The editor also saved the transient sub-channels it built at Finalize; check our expansion matches them."""
    saved = [c for c in o.children.values() if c.short_cls.startswith("PoseSearchFeatureChannel_")]
    if not saved:
        return
    for c in saved:
        c.used.add("<checked>")
        for k in c.props:
            c.used.add(k)
    if len(saved) != len(leaves):
        ctx.warn("%s/%s: expanded %d leaves, editor saved %d sub-channels" % (sb.schema_name, o.name, len(leaves), len(saved)))
        return
    for leaf, c in zip(leaves, saved):
        kind = c.short_cls[len("PoseSearchFeatureChannel_"):]
        q = read_channel(c, kind)
        diffs = [k for k in ("SampleTimeOffset", "Weight", "ComponentStripping", "bNormalize",
                             "bUseCharacterSpaceVelocities", "HeadingAxis", "InputQueryPose")
                 if k in q and k in leaf and _neq(q[k], leaf[k])]
        if kind != leaf["type"] or diffs:
            ctx.warn("%s/%s: leaf %d (%s) differs from saved sub-channel %s in %s" % (
                sb.schema_name, o.name, leaf["index"], leaf["type"], c.name, diffs or "class"))


def _neq(a, b):
    if isinstance(b, dict):
        b = b.get("name")
    if isinstance(a, float) or isinstance(b, float):
        return abs(float(a) - float(b)) > 1e-5
    return a != b


def emit_schemas(ctx):
    out = {}
    for path in ctx.files_by_class["PoseSearchSchema"]:
        for root in ctx.parse(path):
            out[root.name] = convert_schema(root, ctx)
            ctx.account("PoseSearchSchema", root)
    return out


def convert_schema(root, ctx):
    s = {"path": asset_key(root.export_path and ref_path(root.export_path))}
    for k, d in SCHEMA_DEFAULTS.items():
        s[k] = root.get(k, d)
    s["DataPreprocessor"] = enum("EPoseSearchDataPreprocessor", s["DataPreprocessor"], ctx)
    skels = []
    for sk in root.arr("Skeletons"):
        sk = sk if isinstance(sk, dict) else {}
        skels.append({"Skeleton": asset_key(ref_path(sk.get("Skeleton"))),
                      "MirrorDataTable": asset_key(ref_path(sk.get("MirrorDataTable"))),
                      "Role": name_or_none(sk.get("Role"))})
    s["Skeletons"] = skels
    s["MirrorDataTable"] = skels[0]["MirrorDataTable"] if skels else None
    sb = SchemaBuilder(ctx, root.name, [k["Role"] for k in skels] or [None])
    tree = []
    for ref in root.arr("Channels"):
        o = resolve(root, ref)
        if o is None:
            if name_or_none(ref):
                ctx.warn("%s: channel %r not found" % (root.name, ref))
            continue
        expand_channel(o, sb, ctx, "", o.name, tree)
    # Finalize steps 4-5 (Schema.cpp:331-350): auto PermutationTime channel, then padding
    if any(n["type"] in ("Position", "Velocity", "Heading", "Distance") and
           sb.leaves[n["leaves"][0]]["PermutationTimeType"]["name"] != "UseSampleTime" for n in tree if n["leaves"]) \
            and not any(l["type"] == "PermutationTime" for l in sb.leaves):
        sb.add_leaf("PermutationTime", {"Weight": 0.0}, "", "<auto>", {"auto_added": True})
    if s["bAddDataPadding"] and sb.card % 4:
        sb.add_leaf("Padding", {"PaddingSize": sb.card % 4}, "", "<auto>", {"auto_added": True})
    s["cardinality"] = sb.card
    s["bone_references"] = {str(r): b for r, b in sb.bones.items()}
    s["channels"] = tree
    s["leaves"] = sb.leaves
    total = sum(l["Weight"] * l["cardinality"] for l in sb.leaves if l["type"] != "Padding")
    s["sum_of_dimension_weights"] = total
    return s


# ----------------------------------------------------------------------------------------------------------------
# 5. Pose search databases, normalization sets, interaction assets
# ----------------------------------------------------------------------------------------------------------------

DATABASE_DEFAULTS = {  # PoseSearchDatabase.h:508-614
    "ContinuingPoseCostBias": -0.01, "BaseCostBias": 0.0, "LoopingCostBias": -0.005,
    "ContinuingInteractionCostBias": 0.0, "ContinuingContextInteractionCostBias": 0.0,
    "PoseSearchMode": "PCAKDTree", "NumberOfPrincipalComponents": 4, "KDTreeMaxLeafSize": 16,
    "KDTreeQueryNumNeighbors": 200, "PosePruningSimilarityThreshold": 0.0, "PCAValuesPruningSimilarityThreshold": 0.0,
    "KDTreeQueryNumNeighborsWithDuplicates": 0,
}
ENTRY_DEFAULTS = {  # FPoseSearchDatabaseAnimationAsset(Base), PoseSearchDatabase.h:102-176
    "AnimAsset": None, "bEnabled": True, "bDisableReselection": False, "MirrorOption": "UnmirroredOnly",
    "BranchInId": 0, "bUseSingleSample": False, "bUseGridForSampling": False, "NumberOfHorizontalSamples": 9,
    "NumberOfVerticalSamples": 2, "BlendParamX": 0.0, "BlendParamY": 0.0, "SamplingRange": {"Min": 0.0, "Max": 0.0},
}
ASSET_TYPES = {"AnimSequence": "sequence", "AnimComposite": "composite", "AnimMontage": "montage",
               "BlendSpace": "blendspace", "BlendSpace1D": "blendspace", "AimOffsetBlendSpace": "blendspace",
               "AimOffsetBlendSpace1D": "blendspace", "PoseSearchInteractionAsset": "multianim"}


def asset_ref(v):
    """Object reference -> {"asset": key, "asset_class": short class, "asset_type": kind} (None for None)."""
    r = parse_ref(v)
    if not r or not name_or_none(r[1]):
        return None
    cls = short_class(r[0])
    return {"asset": asset_key(r[1]), "asset_class": cls, "asset_type": ASSET_TYPES.get(cls, cls)}


def convert_entry(e, ctx):
    e = merge(ENTRY_DEFAULTS, e if isinstance(e, dict) else {})
    out = asset_ref(e.get("AnimAsset")) or {"asset": None, "asset_class": None, "asset_type": None}
    for k in ("bEnabled", "bDisableReselection", "BranchInId"):
        out[k] = e[k]
    out["MirrorOption"] = enum("EPoseSearchMirrorOption", e["MirrorOption"], ctx)
    out["SamplingRange"] = interval(e["SamplingRange"], 0.0, 0.0)
    out["blendspace_sampling"] = {k: e[k] for k in ("bUseSingleSample", "bUseGridForSampling",
                                                    "NumberOfHorizontalSamples", "NumberOfVerticalSamples",
                                                    "BlendParamX", "BlendParamY")}
    for k in e:
        if k not in ENTRY_DEFAULTS:
            out.setdefault("other", {})[k] = plain(e[k])
    return out


def database_key(o):
    """databases.json key: the asset path key, or `<chooser path key>:<name>` for a database inside a chooser."""
    if o.parent is None:
        return asset_key(ref_path(o.export_path))
    return "%s:%s" % (asset_key(ref_path(o.root.export_path)), o.name)


def convert_database(o, ctx):
    d = {"name": o.name, "path": database_key(o)}
    sch = ref_path(o.raw("Schema"))
    d["schema"] = asset_name(sch)
    d["schema_path"] = asset_key(sch)
    ns = ref_path(o.raw("NormalizationSet"))
    d["normalization_set"] = asset_name(ns)
    d["normalization_set_path"] = asset_key(ns)
    d["Tags"] = [t for t in o.arr("Tags")]
    for k, v in DATABASE_DEFAULTS.items():
        d[k] = o.get(k, v)
    d["PoseSearchMode"] = enum("EPoseSearchMode", d["PoseSearchMode"], ctx)
    d["ExcludeFromDatabaseParameters"] = interval(o.get("ExcludeFromDatabaseParameters", {}), 0.0, -0.3)
    d["AdditionalExtrapolationTime"] = interval(o.get("AdditionalExtrapolationTime", {}), -100.0, 100.0)
    d["entries"] = [convert_entry(e, ctx) for e in o.arr("DatabaseAnimationAssets", (), lambda v, _: v)]
    legacy = o.arr("AnimationAssets_DEPRECATED")
    if legacy:
        ctx.warn("%s: has %d deprecated AnimationAssets entries (not converted)" % (o.name, len(legacy)))
    return d


def emit_databases(ctx):
    out = {}
    for path in ctx.files_by_class["PoseSearchDatabase"]:
        for root in ctx.parse(path):
            out[database_key(root)] = convert_database(root, ctx)
            ctx.account("PoseSearchDatabase", root)
    names = Counter(d["name"] for d in out.values())
    for n, c in names.items():
        if c > 1:
            ctx.warn("database name %s is used by %d assets (databases.json is keyed by path, so all are kept)" % (n, c))
    return out


def emit_normalization_sets(ctx):
    out = {}
    for path in ctx.files_by_class["PoseSearchNormalizationSet"]:
        for root in ctx.parse(path):
            dbs = [ref_path(x) for x in root.arr("Databases")]
            out[root.name] = {"path": asset_key(ref_path(root.export_path)),
                              "databases": [asset_key(p) for p in dbs if p]}
            ctx.account("PoseSearchNormalizationSet", root)
    return out


INTERACTION_ITEM_DEFAULTS = {"Animation": None, "Role": None, "WarpingWeightRotation": 0.5,
                             "WarpingWeightTranslation": 0.5, "Origin": {}}   # PoseSearchInteractionAsset.h:13-45


def emit_interactions(ctx):
    out = {}
    for path in ctx.files_by_class["PoseSearchInteractionAsset"]:
        for root in ctx.parse(path):
            items = []
            for it in root.arr("Items"):
                it = merge(INTERACTION_ITEM_DEFAULTS, it if isinstance(it, dict) else {})
                a = asset_ref(it["Animation"]) or {"asset": None, "asset_class": None, "asset_type": None}
                a.update(Role=name_or_none(it["Role"]), WarpingWeightRotation=it["WarpingWeightRotation"],
                         WarpingWeightTranslation=it["WarpingWeightTranslation"], Origin=transform(it["Origin"]))
                items.append(a)
            out[root.name] = {"path": asset_key(ref_path(root.export_path)), "Items": items,
                              "WarpingBankingWeight": root.get("WarpingBankingWeight", 0.0),
                              "MinimalTranslationWeight": root.get("MinimalTranslationWeight", 0.0)}
            ctx.account("PoseSearchInteractionAsset", root)
    return out


# ----------------------------------------------------------------------------------------------------------------
# 6. Chooser tables
# ----------------------------------------------------------------------------------------------------------------

COLUMN_DEFAULTS = {  # Chooser/Public/*Column.h, PoseSearch/Chooser/PoseSearchChooserColumn.h
    "FloatRangeColumn": {"bWrapInput": False, "MinValue": -180.0, "MaxValue": 180.0},
    "FloatDistanceColumn": {"MaxDistance": 100.0, "CostMultiplier": 1.0, "bFilterOverMaxDistance": False,
                            "bWrapInput": False, "MinValue": -180.0, "MaxValue": 180.0},
    "RandomizeColumn": {"EqualCostThreshold": 0.001, "RepeatProbabilityMultiplier": 1.0,
                        "RepeatProbabilityMultipliers": []},
    "PoseSearchColumn": {"PoseReselectHistory": 0.3, "MaxNumberOfResults": 1},
}
ROW_DEFAULTS = {
    "FloatRangeColumn": {"Min": 0.0, "Max": 0.0, "bNoMin": False, "bNoMax": False},
    "EnumColumn": {"ValueName": "", "Comparison": "MatchEqual", "Value": 0},
    "MultiEnumColumn": {"Value": 0},
    "OutputEnumColumn": {"Value": 0, "ValueName": ""},
    "ChooserNameColumn": {"Comparison": "MatchEqual", "Value": None},
    "FloatDistanceColumn": {"Value": 0.0, "DisableAutoPopulate": False},
    "PoseSearchColumn": {"Data": {}, "Database": None},
    "OutputFloatColumn": None, "RandomizeColumn": None, "BoolColumn": None, "OutputBoolColumn": None,
}
BINDING_DEFAULTS = {"PropertyBindingChain": [], "ContextIndex": 0, "IsBoundToRoot": False, "DisplayName": ""}
COLUMN_HANDLED = {"__type__", "InputValue", "RowValues", "RowValuesWithAny", "FallbackValue", "DefaultRowValue",
                  "bDisabled", "EditorColumnWidth", "RowValues_DEPRECATED", "Chooser"}


def type_name(v):
    return v.get("__type__", "").rsplit(".", 1)[-1] if isinstance(v, dict) else None


def convert_binding(iv, ctx):
    """Context property (FFloatContextProperty etc.) -> where the column reads/writes its value."""
    if not isinstance(iv, dict):
        return None
    b = merge(BINDING_DEFAULTS, iv.get("Binding") if isinstance(iv.get("Binding"), dict) else {})
    chain = [x for x in as_list(b.get("PropertyBindingChain")) if x is not None]
    out = {"type": type_name(iv), "property_chain": chain,
           "property_chain_friendly": [friendly(x) for x in chain],
           "context_index": b["ContextIndex"], "is_bound_to_root": b["IsBoundToRoot"],
           "display_name": b["DisplayName"]}
    for k, name in (("Enum", "enum"), ("StructType", "struct_type"), ("AllowedClass", "allowed_class")):
        if k in b:
            out[name] = asset_key(ref_path(b[k])) if ref_path(b[k]) else None
    for k, v in iv.items():
        if k not in ("__type__", "Binding", "PropertyBindingChain_DEPRECATED"):
            out.setdefault("other", {})[k] = plain(v)
    return out


def struct_value(v, ctx):
    """Instanced user struct -> {"struct": key, "values": {friendly name: value}}."""
    if not isinstance(v, dict):
        return None if v in (None, "None") else plain(v)
    vals = {}
    for k, x in v.items():
        if k == "__type__":
            continue
        vals[friendly(k)] = plain(as_list(x) if x is None else x)
    return {"struct": asset_key(v.get("__type__")), "values": vals}


def convert_cell(ctype, cell, col, ctx, enum_key):
    d = ROW_DEFAULTS.get(ctype)
    if isinstance(d, dict):
        cell = merge(d, cell if isinstance(cell, dict) else {})
    if ctype == "BoolColumn":
        return enum("EBoolColumnCellValue", cell if cell is not None else "MatchAny", ctx)
    if ctype in ("EnumColumn", "OutputEnumColumn"):
        out = {"value": cell["Value"], "value_name": cell["ValueName"] or None}
        if cell["ValueName"]:
            note_enum_value(ctx, enum_key, cell["ValueName"], cell["Value"], "chooser")
            out["display_name"] = ctx.enum_display.get(enum_key, {}).get(cell["ValueName"].split("::")[-1])
        if "Comparison" in cell:
            out["comparison"] = enum("EEnumColumnCellValueComparison", cell["Comparison"], ctx)
        return out
    if ctype == "MultiEnumColumn":
        m = int(cell["Value"])
        return {"mask": m, "values": [i for i in range(32) if m & (1 << i)]}
    if ctype == "ChooserNameColumn":
        return {"comparison": enum("ENameColumnCellValueComparison", cell["Comparison"], ctx),
                "value": name_or_none(cell["Value"])}
    if ctype == "PoseSearchColumn":
        db = ref_path(cell.get("Database"))
        return {"entry": convert_entry(cell.get("Data") or {}, ctx),
                "database": internal_db_key(col, db) if db else None}
    if ctype == "OutputStructColumn":
        return struct_value(cell, ctx)
    if ctype in ("RandomizeColumn", "OutputFloatColumn"):
        return float(cell) if cell is not None else (1.0 if ctype == "RandomizeColumn" else 0.0)
    return plain(cell)


def internal_db_key(owner, db_path):
    """databases.json key of a database reference; one embedded in the chooser is `<chooser key>:<database>`."""
    if db_path.startswith("/"):
        return asset_key(db_path)
    return "%s:%s" % (asset_key(ref_path(owner.root.export_path)), db_path.rsplit(":", 1)[-1].rsplit(".", 1)[-1])


def note_enum_value(ctx, enum_key, value_name, value, source):
    if not enum_key or value_name is None:
        return
    short = value_name.split("::")[-1]
    known = ctx.enum_values[enum_key].get(short)
    if known is not None and known != value:
        ctx.warn("enum %s: %s seen as %s and %s" % (enum_key, short, known, value))
    ctx.enum_values[enum_key][short] = value
    ctx.enum_value_sources[enum_key].add(source)


def convert_column(c, table, ctx, nrows):
    ctype = type_name(c) or "?"
    col = {"type": ctype, "is_output": ctype.startswith("Output"), "bDisabled": bool(c.get("bDisabled", False))}
    col["input"] = convert_binding(c.get("InputValue"), ctx)
    enum_key = (col["input"] or {}).get("enum")
    rows = as_list(c.get("RowValuesWithAny" if ctype == "BoolColumn" else "RowValues"))
    col["row_values"] = [convert_cell(ctype, rows[i] if i < len(rows) else None, table, ctx, enum_key)
                         for i in range(max(nrows, len(rows)))]
    if len(rows) != nrows:
        col["row_values_count"] = len(rows)      # the runtime drops rows past the end of a column's values
    if "FallbackValue" in c:
        col["fallback_value"] = convert_cell(ctype, c["FallbackValue"], table, ctx, enum_key)
    for k, v in COLUMN_DEFAULTS.get(ctype, {}).items():
        col[k] = plain(c.get(k, v))
    for k, v in c.items():
        if k in COLUMN_HANDLED or k in col:
            continue
        if isinstance(v, dict) and "__type__" in v and "Binding" in v:
            col[k] = convert_binding(v, ctx)           # PoseSearchColumn output bindings
        else:
            col[k] = plain(v)
    return col


def convert_result(r, table, ctx):
    t = type_name(r)
    if t is None:
        return None
    if t in ("AssetChooser", "SoftAssetChooser"):
        a = asset_ref(r.get("Asset"))
        return dict({"type": "Asset"}, **(a or {"asset": None}))
    if t == "NestedChooser":
        sub = resolve(table, r.get("Chooser"))
        return {"type": "NestedChooser", "chooser": sub.name if sub else ref_path(r.get("Chooser"))}
    if t == "EvaluateChooser":
        p = ref_path(r.get("Chooser"))
        return {"type": "EvaluateChooser", "chooser": asset_name(p), "chooser_path": asset_key(p)}
    ctx.warn("chooser %s: result type %s kept raw" % (table.name, t))
    return {"type": t, "raw": plain(r)}


def convert_table(t, ctx):
    results = t.arr("ResultsStructs")
    disabled = t.arr("DisabledRows")
    n = len(results)
    out = {"name": t.name}
    if t.parent is None:
        out["ResultType"] = enum("EObjectChooserResultType", t.get("ResultType", "ObjectResult"), ctx)
        out["OutputObjectType"] = short_class(ref_path(t.get("OutputObjectType")))
        ctxdata = []
        for c in t.arr("ContextData"):
            ty = type_name(c)
            if ty is None:
                ctxdata.append(None)
                continue
            target = c.get("Class") or c.get("Struct")
            ctxdata.append({"type": ty, "target": asset_key(ref_path(target)) if ref_path(target) else None,
                            "target_class": short_class(parse_ref(target)[0]) if parse_ref(target) else None,
                            "Direction": enum("EContextObjectDirection", c.get("Direction", "Read"), ctx)})
        out["ContextData"] = ctxdata
    out["columns"] = [convert_column(c, t, ctx, n) for c in t.arr("ColumnsStructs") if c is not None]
    out["rows"] = [{"index": i, "result": convert_result(r, t, ctx),
                    "disabled": bool(disabled[i]) if i < len(disabled) and disabled[i] is not None else False}
                   for i, r in enumerate(results)]
    fb = t.raw("FallbackResult")
    out["fallback_result"] = convert_result(fb, t, ctx) if isinstance(fb, dict) else None
    return out


def emit_choosers(ctx, databases):
    out = {}
    for path in ctx.files_by_class["ChooserTable"]:
        for root in ctx.parse(path):
            tables = {}
            for o in root.walk():
                if o.short_cls == "ChooserTable":
                    tables[o.name] = convert_table(o, ctx)
                elif o.short_cls == "PoseSearchDatabase":       # databases embedded in the chooser (PoseSearchColumn)
                    databases[database_key(o)] = convert_database(o, ctx)
            out[root.name] = {"path": asset_key(ref_path(root.export_path)), "root_table": root.name,
                              "tables": tables}
            ctx.account("ChooserTable", root)
    return out


def emit_proxy_tables(ctx):
    """ProxyTable / ProxyAsset (smart object bench): converted generically."""
    out = {}
    for cls in ("ProxyTable", "ProxyAsset"):
        for path in ctx.files_by_class[cls]:
            for root in ctx.parse(path):
                seen = set()
                out[root.name] = dict(obj_json(root, seen), path=asset_key(ref_path(root.export_path)))
                ctx.account(cls, root, seen)
    return out


# ----------------------------------------------------------------------------------------------------------------
# 7. Animation sequences and montages: notifies, sync markers, curves
# ----------------------------------------------------------------------------------------------------------------

NOTIFY_EVENT_DEFAULTS = {  # FAnimNotifyEvent / FAnimLinkableElement constructors (AnimTypes.h:366, AnimLinkableElement.h:43)
    "LinkValue": 0.0, "LinkMethod": "Absolute", "CachedLinkMethod": "Absolute", "SegmentBeginTime": 0.0,
    "SegmentLength": 0.0, "SlotIndex": 0, "SegmentIndex": -1, "TriggerTimeOffset": 0.0, "EndTriggerTimeOffset": 0.0,
    "TriggerWeightThreshold": 0.00001, "NotifyName": None, "Notify": None, "NotifyStateClass": None, "Duration": 0.0,
    "EndLink": {}, "bConvertedFromBranchingPoint": False, "MontageTickType": "Queued", "NotifyTriggerChance": 1.0,
    "NotifyFilterType": "NoFiltering", "NotifyFilterLOD": 0, "bCanBeFilteredViaRequest": True,
    "bTriggerOnDedicatedServer": True, "bTriggerOnFollower": False, "TrackIndex": 0,
}
NOTIFY_EDITOR_PROPS = {"NotifyColor", "bShouldFireInEditor"}
NOTIFY_EVENT_SKIP = {"Guid", "LinkedSequence", "LinkedMontage", "NotifyColor", "DisplayTime_DEPRECATED"}

WARP_DEFAULTS = {  # URootMotionModifier_Warp, RootMotionModifier.h:355-418
    "WarpTargetName": None, "WarpPointAnimProvider": "None", "WarpPointAnimTransform": {},
    "WarpPointAnimBoneName": None, "bWarpTranslation": True, "bIgnoreZAxis": True, "bWarpToFeetLocation": True,
    "AddTranslationEasingFunc": "HermiteCubic", "AddTranslationEasingCurve": None, "bWarpRotation": True,
    "RotationType": "Default", "RotationMethod": "Slerp", "bSubtractRemainingRootMotion": False,
    "AdditionalRotationOffset": {}, "WarpRotationTimeMultiplier": 1.0, "WarpMaxRotationRate": 0.0,
}
WARP_ENUMS = {"WarpPointAnimProvider": "EWarpPointAnimProvider", "AddTranslationEasingFunc": "EAlphaBlendOption",
              "RotationType": "EMotionWarpRotationType", "RotationMethod": "EMotionWarpRotationMethod"}
# Notify classes whose defaults we fill in (PoseSearchAnimNotifies.h, AnimNotify_PlayMontageNotify.h,
# AnimNotifyState_MotionWarping.h). Anything else (blueprint notifies) lists its non-default properties only.
NOTIFY_DEFAULTS = {
    "AnimNotifyState_PoseSearchExcludeFromDatabase": {},
    "AnimNotifyState_PoseSearchSamplingRange": {},
    "AnimNotifyState_PoseSearchBlockTransition": {},
    "AnimNotifyState_PoseSearchModifyCost": {"CostAddend": -1.0},
    "AnimNotifyState_PoseSearchOverrideContinuingPoseCostBias": {"CostAddend": -1.0},
    "AnimNotifyState_PoseSearchOverrideContinuingInteractionPoseCostBias": {"CostAddend": -1.0},
    "AnimNotifyState_PoseSearchOverrideContinuingContextInteractionCostBias": {"CostAddend": -1.0},
    "AnimNotifyState_PoseSearchSamplingEvent": {"SamplingAttributeId": 0},
    "AnimNotifyState_PoseSearchSamplingAttribute": {"SamplingAttributeId": 0, "Bone": None, "Position": {},
                                                    "Rotation": {}, "LinearVelocity": {}},
    "AnimNotifyState_PoseSearchBranchIn": {"Database": None},
    "AnimNotifyState_PoseSearchConstraint": {"FromSocketName": None, "FromSocketRole": None, "ToSocketName": None,
                                             "ToSocketRole": None, "TranslationWeight": 0.0, "RotationWeight": 0.0,
                                             "RampUpTime": 0.2, "CoolDownTime": 0.2},
    "AnimNotify_PoseSearchEvent": {"EventTag": None},
    "AnimNotify_PlayMontageNotify": {"NotifyName": None},
    "AnimNotify_PlayMontageNotifyWindow": {"NotifyName": None},
    "AnimNotifyState_MotionWarping": {"RootMotionModifier": None},
}

CURVE_KEY_DEFAULT = {"InterpMode": "RCIM_Linear", "TangentMode": "RCTM_Auto", "TangentWeightMode": "RCTWM_WeightedNone",
                     "Time": 0.0, "Value": 0.0, "ArriveTangent": 0.0, "ArriveTangentWeight": 0.0,
                     "LeaveTangent": 0.0, "LeaveTangentWeight": 0.0}   # FRichCurveKey(), RichCurve.h:120
MAX_FLT = 3.4028234663852886e+38


def rich_curve(fc):
    """FRichCurve -> {"times", "values", interpolation and tangents only when they matter}."""
    fc = fc if isinstance(fc, dict) else {}
    keys = [merge(CURVE_KEY_DEFAULT, k if isinstance(k, dict) else {}) for k in as_list(fc.get("Keys"))]
    out = {"times": [float(k["Time"]) for k in keys], "values": [float(k["Value"]) for k in keys]}
    modes = [k["InterpMode"] for k in keys]
    out["interp"] = modes[0] if modes and all(m == modes[0] for m in modes) else modes
    if "RCIM_Cubic" in modes:
        for src, dst in (("TangentMode", "tangent_mode"), ("TangentWeightMode", "tangent_weight_mode"),
                         ("ArriveTangent", "arrive_tangents"), ("LeaveTangent", "leave_tangents"),
                         ("ArriveTangentWeight", "arrive_tangent_weights"),
                         ("LeaveTangentWeight", "leave_tangent_weights")):
            out[dst] = [k[src] for k in keys]
    dv = fc.get("DefaultValue", MAX_FLT)
    out["default_value"] = None if float(dv) >= 3.4e38 else float(dv)
    out["pre_infinity"] = fc.get("PreInfinityExtrap", "RCCE_Constant")
    out["post_infinity"] = fc.get("PostInfinityExtrap", "RCCE_Constant")
    return out


def float_curves(o):
    out = []
    raw = o.get("RawCurveData", {})
    for c in as_list(raw.get("FloatCurves") if isinstance(raw, dict) else None):
        c = c if isinstance(c, dict) else {}
        out.append(dict({"name": name_or_none(c.get("CurveName")), "flags": c.get("CurveTypeFlags", 0)},
                        **rich_curve(c.get("FloatCurve"))))
    return out


def link_time(e):
    m = e.get("CachedLinkMethod", "Absolute")
    if m == "Relative":
        return e["SegmentBeginTime"] + e["LinkValue"]
    if m == "Proportional":
        return e["SegmentBeginTime"] + e["LinkValue"] * e["SegmentLength"]
    return e["LinkValue"]


def cpp_class_of(cls, ctx):
    """Short C++ class name of an object class, walking blueprint parents (BP_X_C -> AnimNotifyState_MotionWarping)."""
    seen = 0
    while cls and cls.startswith("/Game/") and seen < 10:
        cls = ctx.blueprints.get(cls, {}).get("parent")
        seen += 1
    return short_class(cls)


def convert_warp(o, ctx):
    if o is None:
        return None
    o.used.add("<converted>")
    v_obj = layered(o, ctx)
    cpp = cpp_class_of(o.cls, ctx)
    out = {"class": o.short_cls}
    defaults = dict(WARP_DEFAULTS)
    if cpp == "RootMotionModifier_SkewWarp":
        defaults["MaxSpeedClampRatio"] = 0.0
    elif cpp != "RootMotionModifier_Warp":
        seen = set()
        out.update(obj_json(o, seen), defaults_filled=False)
        return out
    for k, d in defaults.items():
        v = v_obj.get(k, d)
        if k in WARP_ENUMS:
            v = enum(WARP_ENUMS[k], v, ctx)
        elif k == "WarpPointAnimTransform":
            v = transform(v)
        elif k == "AdditionalRotationOffset":
            v = rot(v)
        elif k == "AddTranslationEasingCurve":
            v = asset_key(ref_path(v))
        else:
            v = name_or_none(v) if isinstance(v, str) else v
        out[k] = v
    for k in v_obj.prop_names():
        if k not in out:
            out[k] = plain(v_obj.raw(k))
    out["defaults_filled"] = True
    return out


def convert_notify_object(o, ctx, seen):
    if o is None:
        return None
    seen.add(o)
    cpp = cpp_class_of(o.cls, ctx)
    view = layered(o, ctx)
    out = {"class": o.short_cls, "class_path": o.cls}
    is_bp = bool(o.cls and o.cls.startswith("/Game/"))
    if is_bp:
        out["blueprint"] = True
        out["cpp_parent"] = cpp
        out["blueprint_defaults_found"] = len(view.layers) > 1
    props = {}
    defaults = NOTIFY_DEFAULTS.get(cpp)
    if defaults is not None:
        for k, d in defaults.items():
            v = view.get(k, d)
            if k == "RootMotionModifier":
                sub = None
                if v:
                    r = ref_path(v) or v
                    sub = o.child(r.rsplit(".", 1)[-1].split(":")[-1]) or resolve(o, v)
                v = convert_warp(sub, ctx)
            elif k == "Database":
                v = asset_key(ref_path(v)) if ref_path(v) else None
            elif k in ("Position", "LinearVelocity"):
                v = vec(v)
            elif k == "Rotation":
                v = quat(v)
            elif k == "Bone":
                v = bone_name(v)
            elif k == "EventTag":
                v = v.get("TagName") if isinstance(v, dict) else name_or_none(v)
            props[k] = v
    for k in view.prop_names():                  # blueprint variables and anything not in the table above
        if k in props or k in NOTIFY_EDITOR_PROPS:
            o.raw(k)
            continue
        props[k] = _inline(view.raw(k), o, seen, 0)
    if o.custom:
        props["custom_lines"] = list(o.custom)
    out["properties"] = props
    out["defaults_filled"] = defaults is not None or (is_bp and len(view.layers) > 1)
    for c in o.walk():
        if c is not o and c not in seen and not c.used:
            seen.add(c)
    return out


def convert_notifies(o, ctx, seen):
    tracks = [t.get("TrackName") if isinstance(t, dict) else None for t in o.arr("AnimNotifyTracks")]
    out = []
    for e in o.arr("Notifies"):
        e = merge(NOTIFY_EVENT_DEFAULTS, e if isinstance(e, dict) else {})
        state_ref, inst_ref = name_or_none(e["NotifyStateClass"]), name_or_none(e["Notify"])
        obj = resolve(o, state_ref or inst_ref) if (state_ref or inst_ref) else None
        if (state_ref or inst_ref) and obj is None:
            ctx.warn("%s: notify object %r not found" % (o.name, state_ref or inst_ref))
        t = link_time(e)
        n = {"name": name_or_none(e["NotifyName"]), "kind": "state" if state_ref else "notify",
             "class": obj.short_cls if obj else None,
             "time": t, "trigger_time": t + e["TriggerTimeOffset"], "duration": e["Duration"],
             "end_time": t + e["Duration"],
             "end_trigger_time": t + e["Duration"] + e["EndTriggerTimeOffset"] if state_ref else None,
             "track": e["TrackIndex"],
             "track_name": tracks[e["TrackIndex"]] if 0 <= e["TrackIndex"] < len(tracks) else None,
             "TriggerTimeOffset": e["TriggerTimeOffset"], "EndTriggerTimeOffset": e["EndTriggerTimeOffset"],
             "TriggerWeightThreshold": e["TriggerWeightThreshold"], "NotifyTriggerChance": e["NotifyTriggerChance"],
             "MontageTickType": enum("EMontageNotifyTickType", e["MontageTickType"], ctx),
             "bTriggerOnFollower": e["bTriggerOnFollower"], "SlotIndex": e["SlotIndex"],
             "LinkMethod": e["LinkMethod"],
             "object": convert_notify_object(obj, ctx, seen)}
        extra = {k: plain(v) for k, v in e.items() if k not in NOTIFY_EVENT_DEFAULTS and k not in NOTIFY_EVENT_SKIP}
        if extra:
            n["other"] = extra
        out.append(n)
    out.sort(key=lambda n: (n["time"], n["track"]))
    return out, tracks


def sync_markers(o):
    out = []
    for m in o.arr("AuthoredSyncMarkers"):
        m = m if isinstance(m, dict) else {}
        out.append({"name": name_or_none(m.get("MarkerName")), "time": float(m.get("Time", 0.0)),
                    "track": int(m.get("TrackIndex", 0))})
    return sorted(out, key=lambda m: m["time"])


SEQUENCE_DEFAULTS = {  # UAnimSequence / UAnimSequenceBase constructors
    "bLoop": False, "RateScale": 1.0, "bEnableRootMotion": False, "RootMotionRootLock": "RRL_RefPose",
    "bForceRootLock": False, "bUseNormalizedRootMotionScale": True, "Interpolation": "Linear",
    "AdditiveAnimType": "AAT_None", "RefPoseType": "ABPT_None", "RefPoseSeq": None, "SequenceLength": 0.0,
}


def emit_sequences(ctx):
    src = os.path.join(ctx.extracted, "sequences.json")
    base = {}
    if os.path.exists(src):
        with open(src, encoding="utf-8") as f:
            base = json.load(f)
    out = {}
    for path in ctx.files_by_class["AnimSequence"]:
        for root in ctx.parse(path):
            key = asset_key(ref_path(root.export_path))
            seen = set()
            d = dict(base.get(key, {}))
            if not d:
                ctx.warn("sequence %s not in sequences.json" % key)
            for k, v in SEQUENCE_DEFAULTS.items():
                d[k] = root.get(k, v)
            d["RefPoseSeq"] = asset_key(ref_path(d["RefPoseSeq"])) if d["RefPoseSeq"] else None
            d["notifies"], d["notify_tracks"] = convert_notifies(root, ctx, seen)
            d["sync_markers"] = sync_markers(root)
            d["curves"] = float_curves(root)
            fbx = os.path.join(ctx.extracted, "anims", key + ".fbx")
            d["fbx"] = "anims/" + key + ".fbx" if os.path.exists(fbx) else None
            out[key] = d
            ctx.account("AnimSequence", root, seen)
    for key in base:
        if key not in out:
            ctx.warn("sequences.json lists %s but there is no T3D for it" % key)
            out[key] = dict(base[key], t3d_missing=True)
    return dict(sorted(out.items()))


MONTAGE_DEFAULTS = {  # UAnimMontage constructor, AnimMontage.cpp:70-93
    "BlendModeIn": "Standard", "BlendModeOut": "Standard", "BlendOutTriggerTime": -1.0, "bEnableAutoBlendOut": True,
    "SyncGroup": None, "SyncSlotIndex": 0, "RateScale": 1.0, "bLoop": False, "SequenceLength": 0.0,
    "BlendProfileIn": None, "BlendProfileOut": None, "TimeStretchCurveName": "MontageTimeStretchCurve",
}
ALPHA_BLEND_DEFAULT = {"BlendOption": "HermiteCubic", "BlendTime": 0.25, "CustomCurve": None}
SEGMENT_DEFAULT = {"AnimReference": None, "StartPos": 0.0, "AnimStartTime": 0.0, "AnimEndTime": 0.0,
                   "AnimPlayRate": 1.0, "LoopingCount": 1, "CachedPlayLength": 0.0}


def alpha_blend(v, ctx):
    v = merge(ALPHA_BLEND_DEFAULT, v if isinstance(v, dict) else {})
    return {"BlendTime": v["BlendTime"], "BlendOption": enum("EAlphaBlendOption", v["BlendOption"], ctx),
            "CustomCurve": asset_key(ref_path(v["CustomCurve"])) if ref_path(v["CustomCurve"]) else None}


def emit_montages(ctx):
    out = {}
    for path in ctx.files_by_class["AnimMontage"]:
        for root in ctx.parse(path):
            key = asset_key(ref_path(root.export_path))
            seen = set()
            d = {"path": key}
            for k, v in MONTAGE_DEFAULTS.items():
                d[k] = root.get(k, v)
            d["length"] = d.pop("SequenceLength")
            for k in ("BlendProfileIn", "BlendProfileOut"):
                d[k] = ref_path(d[k]).rsplit(":", 1)[-1] if ref_path(d[k]) else None
            d["BlendModeIn"] = enum("EMontageBlendMode", d["BlendModeIn"], ctx)
            d["BlendModeOut"] = enum("EMontageBlendMode", d["BlendModeOut"], ctx)
            d["BlendIn"] = alpha_blend(root.get("BlendIn"), ctx)
            d["BlendOut"] = alpha_blend(root.get("BlendOut"), ctx)
            d["CommonTargetFrameRate"] = root.get("CommonTargetFrameRate", {})
            slots = []
            for i, s in enumerate(root.arr("SlotAnimTracks", [{"SlotName": "DefaultSlot"}],
                                           lambda v, dflt: merge(dflt or {"SlotName": None}, v))):
                s = s or {"SlotName": "DefaultSlot" if i == 0 else None}
                track = s.get("AnimTrack") if isinstance(s.get("AnimTrack"), dict) else {}
                segs = []
                for g in as_list(track.get("AnimSegments")):
                    g = merge(SEGMENT_DEFAULT, g if isinstance(g, dict) else {})
                    a = asset_ref(g["AnimReference"]) or {"asset": None}
                    a.update({k: g[k] for k in SEGMENT_DEFAULT if k != "AnimReference"})
                    segs.append(a)
                slots.append({"SlotName": name_or_none(s.get("SlotName")), "segments": segs})
            d["slots"] = slots
            secs = []
            for s in root.arr("CompositeSections", (), lambda v, _: v):
                s = merge(dict(NOTIFY_EVENT_DEFAULTS, SectionName=None, NextSectionName=None), s or {})
                secs.append({"name": name_or_none(s["SectionName"]), "start_time": link_time(s),
                             "next_section": name_or_none(s["NextSectionName"]), "SlotIndex": s["SlotIndex"],
                             "SegmentIndex": s["SegmentIndex"]})
            d["sections"] = sorted(secs, key=lambda s: s["start_time"])
            d["notifies"], d["notify_tracks"] = convert_notifies(root, ctx, seen)
            d["branching_point_markers"] = [plain(m) for m in root.arr("BranchingPointMarkers")]
            d["branching_point_state_notify_indices"] = [plain(m) for m in root.arr("BranchingPointStateNotifyIndices")]
            d["sync_markers"] = sync_markers(root)
            d["curves"] = float_curves(root)
            out[key] = d
            ctx.account("AnimMontage", root, seen)
    return dict(sorted(out.items()))


# ----------------------------------------------------------------------------------------------------------------
# 8. Blend spaces
# ----------------------------------------------------------------------------------------------------------------

BLEND_PARAM_DEFAULT = {"DisplayName": "None", "Min": 0.0, "Max": 100.0, "GridNum": 4, "bSnapToGrid": False,
                       "bWrapInput": False}                                    # FBlendParameter(), BlendSpace.h:141
BLEND_SAMPLE_DEFAULT = {"Animation": None, "SampleValue": {}, "RateScale": 1.0, "bMirror": False,
                        "bUseSingleFrameForBlending": False, "FrameIndexToSample": 0}   # FBlendSample(), BlendSpace.h
INTERP_PARAM_DEFAULT = {"InterpolationTime": 0.0, "DampingRatio": 1.0, "MaxSpeed": 0.0,
                        "InterpolationType": "BSIT_SpringDamper"}               # FInterpolationParameter, BlendSpace.h:90
BLENDSPACE_DEFAULTS = {
    "TargetWeightInterpolationSpeedPerSec": 0.0, "bTargetWeightInterpolationEaseInOut": True,
    "bAllowMeshSpaceBlending": False, "bLoop": True, "bAllowMarkerBasedSync": True, "bShouldMatchSyncPhases": False,
    "AnimLength": 0.0, "NotifyTriggerMode": "HighestWeightedAnimation", "bInterpolateUsingGrid": False,
    "PreferredTriangulationDirection": "Tangential", "MirrorDataTable": None, "PerBoneBlendMode": "ManualPerBoneOverride",
    "AxisToScaleAnimation": "BSA_None", "bScaleAnimation": False,
}


def emit_blendspaces(ctx):
    out = {}
    for cls in ("BlendSpace", "BlendSpace1D", "AimOffsetBlendSpace", "AimOffsetBlendSpace1D"):
        for path in ctx.files_by_class[cls]:
            for root in ctx.parse(path):
                key = asset_key(ref_path(root.export_path))
                is1d = cls.endswith("1D")
                d = {"path": key, "class": cls, "dimensions": 1 if is1d else 2}
                for k, v in BLENDSPACE_DEFAULTS.items():
                    if is1d and k == "AxisToScaleAnimation" or not is1d and k == "bScaleAnimation":
                        continue
                    d[k] = root.get(k, v)
                d["NotifyTriggerMode"] = enum("ENotifyTriggerMode", d["NotifyTriggerMode"], ctx)
                if "AxisToScaleAnimation" in d:
                    d["AxisToScaleAnimation"] = enum("EBlendSpaceAxis", d["AxisToScaleAnimation"], ctx)
                d["MirrorDataTable"] = asset_key(ref_path(d["MirrorDataTable"])) if ref_path(d["MirrorDataTable"]) else None
                params = root.arr("BlendParameters", [BLEND_PARAM_DEFAULT] * 3, lambda v, df: merge(df, v))
                interp = root.arr("InterpolationParam", [INTERP_PARAM_DEFAULT] * 3, lambda v, df: merge(df, v))
                d["axes"] = []
                for i in range(d["dimensions"]):
                    a = dict(params[i])
                    a["interpolation"] = dict(interp[i])
                    a["interpolation"]["InterpolationType"] = enum("EFilterInterpolationType",
                                                                   a["interpolation"]["InterpolationType"], ctx)
                    d["axes"].append(a)
                samples = []
                for s in root.arr("SampleData", (), lambda v, _: v):
                    s = merge(BLEND_SAMPLE_DEFAULT, s if isinstance(s, dict) else {})
                    a = asset_ref(s["Animation"]) or {"asset": None}
                    pos = vec(s["SampleValue"])
                    a.update(position=pos[:d["dimensions"]], RateScale=s["RateScale"], bMirror=s["bMirror"],
                             bUseSingleFrameForBlending=s["bUseSingleFrameForBlending"],
                             FrameIndexToSample=s["FrameIndexToSample"])
                    samples.append(a)
                d["samples"] = samples
                d["ManualPerBoneOverrides"] = [plain(x) for x in root.arr("ManualPerBoneOverrides")]
                d["PerBoneBlendProfile"] = plain(root.get("PerBoneBlendProfile", {}))
                d["GridSamples"] = [plain(x) for x in root.arr("GridSamples")]
                out[key] = d
                ctx.account(cls, root)
    return dict(sorted(out.items()))


# ----------------------------------------------------------------------------------------------------------------
# 9. Physics asset (ragdoll), physical materials, physics control
# ----------------------------------------------------------------------------------------------------------------

BODY_INSTANCE_DEFAULTS = {  # FBodyInstanceCore() / FBodyInstance(), BodyInstanceCore.cpp:13, BodyInstance.cpp:357
    "bSimulatePhysics": False, "bOverrideMass": False, "bEnableGravity": True, "bStartAwake": True,
    "MassInKgOverride": 100.0, "MassScale": 1.0, "LinearDamping": 0.01, "AngularDamping": 0.0, "COMNudge": {},
    "InertiaTensorScale": {"X": 1.0, "Y": 1.0, "Z": 1.0}, "bUseCCD": False, "bNotifyRigidBodyCollision": False,
    "CollisionEnabled": "QueryAndPhysics", "PositionSolverIterationCount": 8, "VelocitySolverIterationCount": 2,
    "PhysicsBlendWeight": 0.0, "MaxDepenetrationVelocity": 0.0, "bOverrideMaxDepenetrationVelocity": False,
}
SHAPE_BASE = {"Name": None, "RestOffset": 0.0, "bContributeToMass": True, "CollisionEnabled": "QueryAndPhysics"}
SHAPE_DEFAULTS = {  # FKSphereElem(), FKSphylElem(), FKBoxElem(), FKTaperedCapsuleElem()
    "SphereElems": ("sphere", dict(SHAPE_BASE, Center={}, Radius=1.0)),
    "SphylElems": ("capsule", dict(SHAPE_BASE, Center={}, Rotation={}, Radius=1.0, Length=1.0)),
    "BoxElems": ("box", dict(SHAPE_BASE, Center={}, Rotation={}, X=1.0, Y=1.0, Z=1.0)),
    "TaperedCapsuleElems": ("tapered_capsule", dict(SHAPE_BASE, Center={}, Rotation={}, Radius0=1.0, Radius1=1.0,
                                                    Length=1.0, Width=0.0, bOneSidedCollision=False)),
}
DRIVE_DEFAULT = {"Stiffness": 50.0, "Damping": 1.0, "MaxForce": 0.0, "bEnablePositionDrive": False,
                 "bEnableVelocityDrive": False}                              # FConstraintDrive(), ConstraintDrives.cpp:9
CONSTRAINT_BASE = {"Stiffness": 50.0, "Damping": 5.0, "Restitution": 0.0, "ContactDistance": 1.0,
                   "bSoftConstraint": False}                                 # FConstraintBaseParams(), ConstraintTypes.cpp:33
PROFILE_DEFAULT = {  # FConstraintProfileProperties(), ConstraintInstance.cpp:179, + ConstraintTypes.cpp:43-70
    "ProjectionLinearTolerance": 5.0, "ProjectionAngularTolerance": 180.0, "ProjectionLinearAlpha": 1.0,
    "ProjectionAngularAlpha": 0.0, "ShockPropagationAlpha": 0.3, "LinearBreakThreshold": 300.0,
    "LinearPlasticityThreshold": 0.1, "AngularBreakThreshold": 500.0, "AngularPlasticityThreshold": 10.0,
    "ContactTransferScale": 0.0, "bDisableCollision": False, "bParentDominates": False,
    "bEnableShockPropagation": False, "bEnableProjection": True, "bEnableMassConditioning": True,
    "bUseLinearJointSolver": True, "bAngularBreakable": False, "bAngularPlasticity": False, "bLinearBreakable": False,
    "bLinearPlasticity": False, "LinearPlasticityType": "CCPT_Free",
    "LinearLimit": dict(CONSTRAINT_BASE, Limit=0.0, XMotion="LCM_Locked", YMotion="LCM_Locked", ZMotion="LCM_Locked",
                        ContactDistance=5.0, Stiffness=0.0, Damping=0.0),
    "ConeLimit": dict(CONSTRAINT_BASE, Swing1LimitDegrees=45.0, Swing2LimitDegrees=45.0, Swing1Motion="ACM_Free",
                      Swing2Motion="ACM_Free", bSoftConstraint=True, ContactDistance=1.0),
    "TwistLimit": dict(CONSTRAINT_BASE, TwistLimitDegrees=45.0, TwistMotion="ACM_Free", bSoftConstraint=True,
                       ContactDistance=1.0),
    "LinearDrive": {"PositionTarget": {}, "VelocityTarget": {}, "XDrive": DRIVE_DEFAULT, "YDrive": DRIVE_DEFAULT,
                    "ZDrive": DRIVE_DEFAULT},
    "AngularDrive": {"OrientationTarget": {}, "AngularVelocityTarget": {}, "AngularDriveMode": "SLERP",
                     "TwistDrive": DRIVE_DEFAULT, "SwingDrive": DRIVE_DEFAULT, "SlerpDrive": DRIVE_DEFAULT},
}
CONSTRAINT_DEFAULT = {"JointName": None, "ConstraintBone1": None, "ConstraintBone2": None,
                      "Pos1": {}, "PriAxis1": {"X": 1.0}, "SecAxis1": {"Y": 1.0},
                      "Pos2": {}, "PriAxis2": {"X": 1.0}, "SecAxis2": {"Y": 1.0},
                      "AngularRotationOffset": {}, "bScaleLinearLimits": True}   # FConstraintInstance()


def profile(p, ctx):
    p = merge(PROFILE_DEFAULT, p if isinstance(p, dict) else {})
    out = plain(p)
    for k in ("XMotion", "YMotion", "ZMotion"):
        out["LinearLimit"][k] = enum("ELinearConstraintMotion", p["LinearLimit"][k], ctx)
    for k in ("Swing1Motion", "Swing2Motion"):
        out["ConeLimit"][k] = enum("EAngularConstraintMotion", p["ConeLimit"][k], ctx)
    out["TwistLimit"]["TwistMotion"] = enum("EAngularConstraintMotion", p["TwistLimit"]["TwistMotion"], ctx)
    out["AngularDrive"]["AngularDriveMode"] = enum("EAngularDriveMode", p["AngularDrive"]["AngularDriveMode"], ctx)
    for k in ("PositionTarget", "VelocityTarget"):
        out["LinearDrive"][k] = vec(p["LinearDrive"][k])
    out["AngularDrive"]["OrientationTarget"] = rot(p["AngularDrive"]["OrientationTarget"])
    out["AngularDrive"]["AngularVelocityTarget"] = vec(p["AngularDrive"]["AngularVelocityTarget"])
    return out


def emit_physics(ctx):
    out = {"physics_assets": {}, "physical_materials": {}, "physics_control_assets": {}}
    for path in ctx.files_by_class["PhysicsAsset"]:
        for root in ctx.parse(path):
            pa = {"path": asset_key(ref_path(root.export_path)),
                  "PreviewSkeletalMesh": asset_key(ref_path(root.raw("PreviewSkeletalMesh"))),
                  "ConstraintProfiles": [name_or_none(x) for x in root.arr("ConstraintProfiles")],
                  "SolverSettings": plain(root.get("SolverSettings", {})),
                  "bodies": [], "constraints": []}
            for ref in root.arr("SkeletalBodySetups"):
                b = resolve(root, ref)
                if b is None:
                    ctx.warn("%s: body %r not found" % (root.name, ref))
                    continue
                inst = merge(BODY_INSTANCE_DEFAULTS, b.get("DefaultInstance", {}))
                inst = {k: (vec(v, (1.0, 1.0, 1.0)) if k == "InertiaTensorScale" else vec(v)) if k in (
                    "COMNudge", "InertiaTensorScale") else plain(v) for k, v in inst.items()}
                shapes = []
                agg = b.get("AggGeom", {})
                for kind, (sname, sd) in SHAPE_DEFAULTS.items():
                    for e in as_list(agg.get(kind) if isinstance(agg, dict) else None):
                        e = merge(sd, e if isinstance(e, dict) else {})
                        s = {"type": sname}
                        for k, v in e.items():
                            s[k] = vec(v) if k == "Center" else rot(v) if k == "Rotation" else plain(v)
                        shapes.append(s)
                for kind in (agg or {}):
                    if kind not in SHAPE_DEFAULTS:
                        shapes.append({"type": kind, "raw": plain(agg[kind])})
                pa["bodies"].append({
                    "name": b.name, "bone": name_or_none(b.get("BoneName")),
                    "PhysicsType": enum("EPhysicsType", b.get("PhysicsType", "PhysType_Default"), ctx),
                    "CollisionTraceFlag": enum("ECollisionTraceFlag", b.get("CollisionTraceFlag", "CTF_UseDefault"), ctx),
                    "PhysMaterial": asset_key(ref_path(b.raw("PhysMaterial"))),
                    "bConsiderForBounds": b.get("bConsiderForBounds", True),
                    "body_instance": inst, "shapes": shapes})
                for k in b.unused():
                    pa["bodies"][-1].setdefault("other", {})[k] = plain(b.raw(k))
            for ref in root.arr("ConstraintSetup"):
                c = resolve(root, ref)
                if c is None:
                    ctx.warn("%s: constraint %r not found" % (root.name, ref))
                    continue
                ci = merge(CONSTRAINT_DEFAULT, c.get("DefaultInstance", {}))
                con = {"name": c.name, "JointName": name_or_none(ci["JointName"]),
                       "child_bone": name_or_none(ci["ConstraintBone1"]),
                       "parent_bone": name_or_none(ci["ConstraintBone2"]),
                       "frame1": {"Pos": vec(ci["Pos1"]), "PriAxis": vec(ci["PriAxis1"]), "SecAxis": vec(ci["SecAxis1"])},
                       "frame2": {"Pos": vec(ci["Pos2"]), "PriAxis": vec(ci["PriAxis2"]), "SecAxis": vec(ci["SecAxis2"])},
                       "AngularRotationOffset": rot(ci["AngularRotationOffset"]),
                       "bScaleLinearLimits": ci["bScaleLinearLimits"],
                       "profile": profile(ci.get("ProfileInstance"), ctx),
                       "named_profiles": []}
                for h in c.arr("ProfileHandles"):
                    h = h if isinstance(h, dict) else {}
                    con["named_profiles"].append({"name": name_or_none(h.get("ProfileName")),
                                                  "profile": profile(h.get("ProfileProperties"), ctx)})
                extra = {k: plain(v) for k, v in ci.items() if k not in CONSTRAINT_DEFAULT and k != "ProfileInstance"}
                if extra:
                    con["other"] = extra
                pa["constraints"].append(con)
            out["physics_assets"][root.name] = pa
            ctx.account("PhysicsAsset", root)
    for cls, slot in (("PhysicalMaterial", "physical_materials"), ("PhysicsControlAsset", "physics_control_assets")):
        for path in ctx.files_by_class[cls]:
            for root in ctx.parse(path):
                seen = set()
                out[slot][root.name] = dict(obj_json(root, seen), path=asset_key(ref_path(root.export_path)),
                                            defaults_filled=False)
                ctx.account(cls, root, seen)
    return out


# ----------------------------------------------------------------------------------------------------------------
# 10. Mirror table, float curves, user enums, user structs
# ----------------------------------------------------------------------------------------------------------------

def emit_mirror_tables(ctx):
    out = {}
    for path in ctx.files_by_class["MirrorDataTable"]:
        for root in ctx.parse(path):
            exprs = []
            for e in root.arr("MirrorFindReplaceExpressions"):
                e = merge({"FindExpression": None, "ReplaceExpression": None, "FindReplaceMethod": "Prefix"}, e or {})
                exprs.append({"find": e["FindExpression"], "replace": e["ReplaceExpression"],
                              "method": enum("EMirrorFindReplaceMethod", e["FindReplaceMethod"], ctx)})
            out[root.name] = {
                "path": asset_key(ref_path(root.export_path)),
                "skeleton": asset_key(ref_path(root.raw("Skeleton"))),
                "MirrorAxis": enum("EAxis", root.get("MirrorAxis", "X"), ctx),     # constructor default X
                "bMirrorRootMotion": root.get("bMirrorRootMotion", True),
                "find_replace_expressions": exprs,
                "rows": None,
                "rows_note": "DataTable rows are serialized natively and are not part of the T3D dump. UE fills the "
                             "table by applying find_replace_expressions, in order, to every skeleton bone name; the "
                             "first expression whose result is a different, existing bone gives the mirror bone.",
            }
            ctx.account("MirrorDataTable", root)
    return out


def emit_curves(ctx):
    out = {}
    for path in ctx.files_by_class["CurveFloat"]:
        for root in ctx.parse(path):
            out[root.name] = dict(path=asset_key(ref_path(root.export_path)), **rich_curve(root.get("FloatCurve")))
            ctx.account("CurveFloat", root)
    return out


def text_value(v):
    """NSLOCTEXT("ns", "key", "Text") / LOCTEXT / plain string -> "Text"."""
    if isinstance(v, dict) and v.get("__type__") in ("NSLOCTEXT", "LOCTEXT", "INVTEXT", "LOCGEN_NUMBER"):
        items = v.get("__items__", [])
        return items[-1] if items else None
    return v


def load_enums(ctx):
    """Parse user enums early: choosers need their display names."""
    ctx.enums = {}
    ctx.enum_display = {}
    for path in ctx.files_by_class["UserDefinedEnum"]:
        for root in ctx.parse(path):
            key = asset_key(ref_path(root.export_path))
            entries = []
            for pair in as_list(root.raw("DisplayNameMap")):
                if isinstance(pair, list) and len(pair) == 2:
                    entries.append((pair[0], text_value(pair[1])))
            ctx.enum_display[key] = dict(entries)
            ctx.enums[root.name] = {"path": key, "description": text_value(root.get("EnumDescription")),
                                    "entries": entries}
            ctx.account("UserDefinedEnum", root)


def emit_enums(ctx):
    out = {}
    for name, e in ctx.enums.items():
        key = e["path"]
        values = ctx.enum_values.get(key, {})
        rows = []
        for short, disp in e["entries"]:
            rows.append({"name": short, "full_name": "%s::%s" % (name, short), "display_name": disp,
                         "value": values.get(short)})
        rows.sort(key=lambda r: (r["value"] is None, r["value"] if r["value"] is not None else 0, r["name"]))
        if any(r["value"] is None for r in rows):
            if not values:
                ctx.warn("enum %s: numeric values unknown (not used by any chooser or blueprint switch)" % name)
            else:
                ctx.warn("enum %s: some numeric values unknown" % name)
        out[name] = {"path": key, "description": e["description"], "entries": rows,
                     "value_source": sorted(ctx.enum_value_sources.get(key, [])),
                     "max_value": len(rows)}
    return out


def emit_structs(ctx):
    out = {}
    for path in ctx.files_by_class["UserDefinedStruct"]:
        for root in ctx.parse(path):
            ed = resolve(root, root.raw("EditorData"))
            fields = []
            if ed is not None:
                for v in ed.arr("VariablesDescriptions"):
                    v = v if isinstance(v, dict) else {}
                    fields.append({"name": friendly(v.get("VarName")), "var_name": v.get("VarName"),
                                   "friendly_name": v.get("FriendlyName"), "category": v.get("Category"),
                                   "sub_category": v.get("SubCategory"),
                                   "sub_category_object": asset_key(ref_path(v.get("SubCategoryObject")))
                                   if ref_path(v.get("SubCategoryObject")) else v.get("SubCategoryObject"),
                                   "container_type": v.get("ContainerType", "None"),
                                   "default_value": v.get("DefaultValue"), "tooltip": v.get("ToolTip"),
                                   "other": {k: plain(x) for k, x in v.items() if k not in (
                                       "VarName", "VarGuid", "FriendlyName", "Category", "SubCategory",
                                       "SubCategoryObject", "ContainerType", "DefaultValue", "ToolTip",
                                       "CurrentDefaultValue")}})
                ed.raw("ToolTip")
                ed.raw("MetaData")
            out[root.name] = {"path": asset_key(ref_path(root.export_path)), "guid": root.get("Guid"),
                              "tooltip": ed.get("ToolTip") if ed else None, "fields": fields}
            ctx.account("UserDefinedStruct", root)
    return out


# ----------------------------------------------------------------------------------------------------------------
# 11. Discovery, blueprint scan, index, run
# ----------------------------------------------------------------------------------------------------------------

_BP_LINE = re.compile(r'^   (ParentClass|GeneratedClass|FunctionGraphs\(\d+\))=(.*)$')
_ENUM_LINE = re.compile(r'^(\s+)Enum="?([^"]*UserDefinedEnum\'[^\']+\')"?\s*$')
_ENTRY_LINE = re.compile(r'^(\s+)EnumEntries\((\d+)\)="?([^"]*)"?\s*$')
BLUEPRINT_CLASSES = ("Blueprint", "AnimBlueprint", "ControlRigBlueprint", "WidgetBlueprint")


def discover(ctx):
    for dp, dn, fn in os.walk(ctx.t3d_dir):
        dn.sort()
        for f in sorted(fn):
            if not f.endswith(".t3d"):
                continue
            p = os.path.join(dp, f)
            with open(p, encoding="utf-8-sig") as fh:
                first = fh.readline()
            m = _BEGIN.match(first)
            cls = dict(_ATTR.findall(m.group(1))).get("Class") if m else None
            cls = unquote(cls) if cls else None
            if f.endswith(".defaults.t3d"):            # blueprint class defaults, written by export_cdo.py
                ctx.cdo_files[cls] = p
                continue
            ctx.files_by_class[short_class(cls) if cls else "?"].append(p)


def scan_blueprints(ctx):
    """Blueprint parent classes and function names (for blueprint channels and notifies), plus the enumerator order
    of user enums from switch/enum nodes (`Enum=...` followed by `EnumEntries(i)=...`)."""
    for cls in BLUEPRINT_CLASSES:
        for p in ctx.files_by_class[cls]:
            info = {"parent": None, "functions": [], "blueprint": ctx.rel(p)}
            gen = None
            enum_ref, enum_indent, entries = None, None, []
            with open(p, encoding="utf-8-sig") as fh:
                for line in fh:
                    m = _BP_LINE.match(line)
                    if m:
                        k, v = m.group(1), parse_value(m.group(2))
                        if k == "ParentClass":
                            info["parent"] = ref_path(v)
                        elif k == "GeneratedClass":
                            gen = ref_path(v)
                        else:
                            sub = ref_path(v)
                            info["functions"].append(sub.rsplit(".", 1)[-1].split(":")[-1] if sub else v)
                        continue
                    m = _ENUM_LINE.match(line)
                    if m:
                        _flush_enum(ctx, enum_ref, entries)
                        enum_ref, enum_indent, entries = ref_path(m.group(2)), m.group(1), []
                        continue
                    m = _ENTRY_LINE.match(line)
                    if m and enum_ref and m.group(1) == enum_indent:
                        entries.append((int(m.group(2)), m.group(3)))
                        continue
                    if enum_ref and line.strip() == "End Object":
                        _flush_enum(ctx, enum_ref, entries)
                        enum_ref, entries = None, []
            _flush_enum(ctx, enum_ref, entries)
            root_name = os.path.splitext(os.path.basename(p))[0]
            pkg = "/Game/" + os.path.splitext(ctx.rel(p))[0]
            gen_name = (gen or root_name + "_C").rsplit(".", 1)[-1].split("'")[0]
            ctx.blueprints["%s.%s" % (pkg, gen_name)] = info


def _flush_enum(ctx, enum_ref, entries):
    if not enum_ref or not entries:
        return
    key = asset_key(enum_ref)
    for i, name in sorted(entries):
        note_enum_value(ctx, key, name, i, "blueprint")


def write_json(ctx, name, data):
    os.makedirs(ctx.out_dir, exist_ok=True)
    with open(os.path.join(ctx.out_dir, name), "w", encoding="utf-8", newline="\n") as f:
        json.dump(data, f, indent=1, ensure_ascii=False, allow_nan=False, default=str)
        f.write("\n")


CONVERTED_ROOT_CLASSES = {
    "PoseSearchSchema", "PoseSearchDatabase", "PoseSearchNormalizationSet", "PoseSearchInteractionAsset",
    "ChooserTable", "ProxyTable", "ProxyAsset", "AnimSequence", "AnimMontage", "BlendSpace", "BlendSpace1D",
    "AimOffsetBlendSpace", "AimOffsetBlendSpace1D", "PhysicsAsset", "PhysicalMaterial", "PhysicsControlAsset",
    "MirrorDataTable", "CurveFloat", "UserDefinedEnum", "UserDefinedStruct",
}

CONVENTIONS = {
    "units": "Unreal units and axes as stored: cm, cm/s, seconds, degrees, Z-up, X-forward, left-handed.",
    "asset keys": "Assets under /Game/Characters/UEFN_Mannequin/Animations are referenced by their path relative to "
                  "that folder (the sequences.json and anims/<key>.fbx key); other assets keep their /Game package "
                  "path. sequences, montages, blendspaces and databases.json are keyed by that path key (two "
                  "databases share a name); schemas, normalization sets, choosers, interactions, curves, enums and "
                  "structs by asset name (unique). A database embedded in a chooser is '<chooser key>:<database>'.",
    "enums": "C++ enum values are {\"name\", \"value\"}. User enums keep their enumerator name; enums.json maps "
             "names to display names and numeric values.",
    "defaults": "Every property the T3D omits is filled with its C++ default, except objects of blueprint classes "
                "(notifies, warp modifiers, physics control): their blueprint class defaults are not in the dump, so "
                "they list only exported properties and carry defaults_filled=false.",
    "schemas.leaves": "Leaf feature channels in feature-vector order. weight is the effective weight (for Trajectory "
                      "and Pose expansions: sample/bone weight x channel weight; Group has no weight). offset and "
                      "cardinality give the slice of the feature vector. label is the string UE compares in "
                      "CanBeNormalizedWith: two leaves normalize together when class and cardinality match and either "
                      "they share a non-null NormalizationGroup or their labels are equal (greedy grouping, first "
                      "group whose first member matches).",
    "notifies": "time is the notify's link time in the asset; trigger_time adds TriggerTimeOffset.",
}


def run(extracted, verbose=True):
    """Convert <extracted>/t3d into <extracted>/data. Returns the index dict."""
    import time
    t0 = time.time()
    ctx = Context(os.path.abspath(extracted))
    if not os.path.isdir(ctx.t3d_dir):
        raise SystemExit("no t3d folder in %s" % ctx.extracted)
    discover(ctx)
    scan_blueprints(ctx)
    load_enums(ctx)
    outputs = {}
    outputs["schemas.json"] = emit_schemas(ctx)
    databases = emit_databases(ctx)
    outputs["normalization_sets.json"] = emit_normalization_sets(ctx)
    outputs["choosers.json"] = emit_choosers(ctx, databases)
    outputs["choosers.json"]["__proxy_tables__"] = emit_proxy_tables(ctx)
    outputs["databases.json"] = databases
    outputs["interactions.json"] = emit_interactions(ctx)
    outputs["sequences.json"] = emit_sequences(ctx)
    outputs["montages.json"] = emit_montages(ctx)
    outputs["blendspaces.json"] = emit_blendspaces(ctx)
    outputs["physics_asset.json"] = emit_physics(ctx)
    outputs["mirror_table.json"] = emit_mirror_tables(ctx)
    outputs["curves.json"] = emit_curves(ctx)
    outputs["structs.json"] = emit_structs(ctx)
    outputs["enums.json"] = emit_enums(ctx)
    for name, data in outputs.items():
        write_json(ctx, name, data)

    not_converted = {cls: len(files) for cls, files in ctx.files_by_class.items()
                     if cls not in CONVERTED_ROOT_CLASSES and files}
    not_converted["<blueprint class defaults (.defaults.t3d): read only as defaults for notifies and channels>"] = \
        len(ctx.cdo_files)
    index = {
        "source": "t3d/ (written by tools/unreal/export_gasp.py)",
        "converter": "tools/unreal/t3d_to_json.py",
        "seconds": round(time.time() - t0, 1),
        "counts": {
            "schemas": len(outputs["schemas.json"]),
            "databases": len(databases),
            "database_entries": sum(len(d["entries"]) for d in databases.values()),
            "normalization_sets": len(outputs["normalization_sets.json"]),
            "chooser_assets": len(outputs["choosers.json"]) - 1,
            "chooser_tables": sum(len(c["tables"]) for k, c in outputs["choosers.json"].items()
                                  if k != "__proxy_tables__"),
            "proxy_tables": len(outputs["choosers.json"]["__proxy_tables__"]),
            "sequences": len(outputs["sequences.json"]),
            "sequence_notifies": sum(len(s.get("notifies", [])) for s in outputs["sequences.json"].values()),
            "sequence_curves": sum(len(s.get("curves", [])) for s in outputs["sequences.json"].values()),
            "montages": len(outputs["montages.json"]),
            "blendspaces": len(outputs["blendspaces.json"]),
            "interactions": len(outputs["interactions.json"]),
            "physics_bodies": sum(len(p["bodies"]) for p in outputs["physics_asset.json"]["physics_assets"].values()),
            "physics_constraints": sum(len(p["constraints"])
                                       for p in outputs["physics_asset.json"]["physics_assets"].values()),
            "mirror_tables": len(outputs["mirror_table.json"]),
            "curves": len(outputs["curves.json"]),
            "enums": len(outputs["enums.json"]),
            "structs": len(outputs["structs.json"]),
            "t3d_files": sum(len(v) for v in ctx.files_by_class.values()),
        },
        "files": sorted(outputs) + ["index.json"],
        "conventions": CONVENTIONS,
        "not_converted_assets": dict(sorted(not_converted.items())),
        "unconverted_subobjects": {k: dict(v.most_common()) for k, v in sorted(ctx.unconverted_objects.items())},
        "unparsed_properties": {k: dict(v.most_common()) for k, v in sorted(ctx.unparsed_props.items())},
        "ignored_properties": {k: dict(v.most_common()) for k, v in sorted(ctx.ignored_props.items())},
        "ignored_subobjects": dict(ctx.ignored_objects.most_common()),
        "parse_problems": ctx.parse_problems,
        "warnings": sorted(set(ctx.warnings)),
    }
    write_json(ctx, "index.json", index)
    if verbose:
        print("t3d_to_json: wrote %d files to %s in %.1fs" % (len(index["files"]), ctx.out_dir, index["seconds"]))
        for k, v in index["counts"].items():
            print("  %-22s %s" % (k, v))
        print("  warnings: %d, parse problems: %d, unparsed property groups: %d" % (
            len(index["warnings"]), len(ctx.parse_problems), len(index["unparsed_properties"])))
    return index


if __name__ == "__main__":
    if len(sys.argv) != 2:
        print("usage: python t3d_to_json.py <extracted dir>")
        sys.exit(2)
    run(sys.argv[1])
