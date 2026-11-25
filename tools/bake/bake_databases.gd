# godot --headless --path . --script res://tools/bake/bake_databases.gd [-- <database name filter>]
# Builds every pose search database of the Game Animation Sample from extracted/data/*.json into
# res://databases/<sample path>.res, following Unreal 5.8's indexer:
# sampling ranges and the end trim, exclusion/block/cost notifies, per-normalization-set deviation,
# and sqrt(w / sum w) / deviation weights. Features are computed in Unreal units (cm, cm/s) in the
# root bone's frame, so Unreal's constants (min deviation 0.1, clamp to size 1) apply unchanged.
# Montage entries sample their slot's single segment (the sequence, with its start and rate) using the
# montage's own notifies; databases embedded in choosers (PoseSearchColumn "<chooser>:<db>", listed
# with no entries in databases.json) get the column's row entries when those are all montages, and are
# written to databases/<chooser>/<db>.res.
# Multi-character entries (PoseSearchInteractionAsset, "multianim") sample every role's montage at the
# same asset time, each role's root placed by the item's Origin (RootTransform = root motion * Origin,
# PoseSearchAssetSampler.cpp), over the longest montage, with the notifies of all roles
# (PoseSearchDerivedData.cpp FindValidRanges); the entry's clip is stored as "psia:<asset path>" and
# pose times are asset (montage) times.
extends SceneTree

const DATA := "res://extracted/data/"
const ANIMS := "res://extracted/anims/"
const OUT_DIR := "res://databases/"
const UE_SCALE := 100.0  # m -> cm
const FINITE_DELTA := 1.0 / 60.0
const MIN_DEVIATION := 0.1
const NOTIFY_HALF_INTERVAL := 1.0 / 240.0  # notifies are read over 1/120 s around the sample

var schemas: Dictionary
var databases: Dictionary
var norm_sets: Dictionary
var sequences: Dictionary
var montages: Dictionary
var interactions: Dictionary
var skeleton: Skeleton3D
var up_axis := -1  # root-local axis that points up (Unreal's Z)
var bone_index := {}
var samplers := {}
var indexed := {}  # "db|schema" -> {rows: PackedFloat32Array, ...}
var skipped := []


func _initialize() -> void:
	schemas = _json("schemas.json")
	databases = _json("databases.json")
	norm_sets = _json("normalization_sets.json")
	sequences = _json("sequences.json")
	montages = _json("montages.json")
	interactions = _json("interactions.json")
	_fill_chooser_entries(_json("choosers.json"))
	# Features are measured on the skeleton the clips were made for, as Unreal does (the rendered
	# Manny has other limb lengths and no attach bone, which the traversal channels read).
	skeleton = Mannequin.clip_skeleton()
	_find_up_axis()
	DirAccess.make_dir_recursive_absolute(ProjectSettings.globalize_path(OUT_DIR))

	var filter: String = OS.get_cmdline_user_args()[0] if OS.get_cmdline_user_args().size() > 0 else ""
	var started := Time.get_ticks_msec()
	var built := 0
	for db_path: String in databases:
		var db: Dictionary = databases[db_path]
		if filter != "" and not filter in db_path:
			continue
		var res := _build(db_path)
		if res == null:
			continue
		# Keeps the sample's folders (two databases share a name); a chooser's embedded database
		# "<chooser>:<db>" goes to "<chooser>/<db>" (":" is not allowed in Windows file names).
		var out_path := OUT_DIR + db_path.replace(":", "/") + ".res"
		DirAccess.make_dir_recursive_absolute(ProjectSettings.globalize_path(out_path.get_base_dir()))
		ResourceSaver.save(res, out_path)
		built += 1
		print("DB %-55s poses=%5d dims=%d" % [db_path.get_file(), res.pose_count(), res.dims])
	print("BAKED %d databases in %.1f s, skipped entries: %d" % [built, (Time.get_ticks_msec() - started) / 1000.0, skipped.size()])
	for s in skipped.slice(0, 20):
		print("  skipped ", s)
	quit()


## Databases embedded in a chooser (a PoseSearchColumn's "<chooser>:<db>") list no entries in
## databases.json: their entries are the column's row values. Filled in here for the montage
## databases (traversal, get-up, bench), so they build like the others.
func _fill_chooser_entries(choosers: Dictionary) -> void:
	var found := {}
	for c in choosers.values():
		if not (c is Dictionary) or not c.has("tables"):
			continue
		for t: Dictionary in c["tables"].values():
			for col: Dictionary in t["columns"]:
				if col.get("type") != "PoseSearchColumn":
					continue
				for cell in col.get("row_values", []):
					if not (cell is Dictionary) or not cell.has("database") or not (cell["entry"] is Dictionary):
						continue
					if cell["entry"].get("asset") == null:
						continue
					if not found.has(cell["database"]):
						found[cell["database"]] = []
					found[cell["database"]].append(cell["entry"])
	for db_path: String in found:
		if not databases.has(db_path) or not (databases[db_path]["entries"] as Array).is_empty():
			continue
		var entries: Array = found[db_path]
		if entries.any(func(e): return e.get("asset_type") != "montage"):
			continue
		databases[db_path]["entries"] = entries


func _json(name: String) -> Dictionary:
	return JSON.parse_string(FileAccess.get_file_as_string(DATA + name))


## The clip root's local frame is Unreal's component frame; find which of its axes is up
## (from feet to head in the idle pose, so it doesn't depend on how the skeleton is parented).
func _find_up_axis() -> void:
	var s := _sampler("Idle/M_Neutral_Stand_Idle_Loop")
	var root_xf := s.bone(skeleton.find_bone("root"), 0.0)
	var feet := (s.bone(skeleton.find_bone("foot_l"), 0.0).origin + s.bone(skeleton.find_bone("foot_r"), 0.0).origin) * 0.5
	var up := (root_xf.basis.inverse() * (s.bone(skeleton.find_bone("head"), 0.0).origin - feet)).normalized()
	var a := up.abs()
	up_axis = 0 if a.x > 0.95 else (1 if a.y > 0.95 else (2 if a.z > 0.95 else -1))
	assert(up_axis >= 0, "root frame is not axis aligned: %s" % up)
	print("root-local up axis: ", up_axis, " ", up)


func _sampler(asset: String) -> ClipSampler:
	if samplers.has(asset):
		return samplers[asset]
	var lib: AnimationLibrary = load(ANIMS + asset + ".fbx")
	if lib == null:
		return null
	var anim := lib.get_animation(lib.get_animation_list()[0])
	var info: Dictionary = sequences.get(asset, {})
	var s := ClipSampler.new(anim, skeleton, info.get("bLoop", false), info.get("curves", []))
	samplers[asset] = s
	return s


func _bone(name) -> int:
	if name == null:
		return skeleton.find_bone("root")
	if not bone_index.has(name):
		bone_index[name] = skeleton.find_bone(name)
	return bone_index[name]


# ---------------------------------------------------------------- one database

func _build(db_path: String) -> PoseDatabase:
	var db: Dictionary = databases[db_path]
	var schema: Dictionary = schemas.get(db["schema"], {})
	if schema.is_empty():
		skipped.append("%s: no schema %s" % [db_path, db["schema"]])
		return null
	var main := _index(db_path, db["schema"])
	if main["poses"] == 0:
		return null

	# Deviation per channel group over this database and its normalization set (spec 1.2).
	var prep: String = schema["DataPreprocessor"]["name"]
	var sources := [main]
	var set_name = db.get("normalization_set")
	if set_name and norm_sets.has(set_name):
		for other: String in norm_sets[set_name]["databases"]:
			if other == db_path or not databases.has(other):
				continue
			var other_schema: String = db["schema"] if prep == "NormalizeWithCommonSchema" else databases[other]["schema"]
			if schemas.has(other_schema):
				sources.append(_index(other, other_schema))
	var leaves: Array = schema["leaves"]
	var dims: int = schema["cardinality"]
	var deviation := PackedFloat32Array()
	deviation.resize(dims)
	deviation.fill(1.0)
	if prep != "None":
		var done := {}
		for leaf: Dictionary in leaves:
			var key := _group_key(leaf)
			if done.has(key):
				continue
			done[key] = true
			var dev := _group_deviation(key, int(leaf["cardinality"]), sources)
			if dev <= MIN_DEVIATION:
				dev = 1.0
			for l2: Dictionary in leaves:
				if _group_key(l2) == key:
					for i in int(l2["cardinality"]):
						deviation[int(l2["offset"]) + i] = dev

	# Weights (spec 1.2): w / sum w (Normalize variants), sqrt, / deviation.
	var w := PackedFloat32Array()
	w.resize(dims)
	var total := 0.0
	for leaf: Dictionary in leaves:
		for i in int(leaf["cardinality"]):
			w[int(leaf["offset"]) + i] = float(leaf["Weight"])
			total += float(leaf["Weight"])
	for d in dims:
		var wd := w[d]
		if prep in ["Normalize", "NormalizeWithCommonSchema"] and total > 1e-8:
			wd /= total
		wd = sqrt(wd)
		if prep != "None" and deviation[d] > 1e-8:
			wd /= deviation[d]
		w[d] = wd

	var res := PoseDatabase.new()
	res.db_name = db_path.get_file()
	res.db_path = db_path
	res.schema_name = db["schema"]
	res.sample_rate = float(schema["SampleRate"])
	res.dims = dims
	res.weights = w
	for leaf: Dictionary in leaves:
		res.leaves.append(leaf)
	res.continuing_pose_cost_bias = float(db.get("ContinuingPoseCostBias", -0.01))
	res.entry_clip = main["entry_clip"]
	res.entry_loops = main["entry_loops"]
	res.entry_disable_reselection = main["entry_disable"]
	res.entry_length = main["entry_length"]
	res.pose_entry = main["pose_entry"]
	res.pose_time = main["pose_time"]
	res.pose_addend = main["pose_addend"]
	res.pose_blocked = main["pose_blocked"]
	res.pose_continuing_bias = main["pose_cont"]
	var values: PackedFloat32Array = main["rows"].duplicate()
	for p in main["poses"]:
		for d in dims:
			values[p * dims + d] *= w[d]
	res.values = values
	return res


## Unreal groups leaves for normalization when class and cardinality match and either the
## NormalizationGroup (if set) or the label is the same (FeatureChannel.cpp:93-129).
static func _group_key(leaf: Dictionary) -> String:
	var group = leaf.get("NormalizationGroup")
	var tag: String = ("G:" + str(group)) if group != null and str(group) != "None" else ("L:" + str(leaf["label"]))
	return "%s|%d|%s" % [leaf["type"], int(leaf["cardinality"]), tag]


## Mean over rows of |row - mean row|, rows being every matching leaf's values in every pose of every source.
static func _group_deviation(key: String, card: int, sources: Array) -> float:
	var mean := PackedFloat64Array()
	mean.resize(card)
	var count := 0
	for pass_index in 2:
		var norm_sum := 0.0
		for src: Dictionary in sources:
			var rows: PackedFloat32Array = src["rows"]
			var dims: int = src["dims"]
			for leaf: Dictionary in src["leaves"]:
				if _group_key(leaf) != key:
					continue
				var off := int(leaf["offset"])
				for p in src["poses"]:
					var base: int = p * dims + off
					if pass_index == 0:
						for i in card:
							mean[i] += rows[base + i]
						count += 1
					else:
						var sq := 0.0
						for i in card:
							var d := rows[base + i] - mean[i]
							sq += d * d
						norm_sum += sqrt(sq)
		if count == 0:
			return 1.0
		if pass_index == 0:
			for i in card:
				mean[i] /= count
		else:
			return norm_sum / count
	return 1.0


# ---------------------------------------------------------------- indexing

## Raw (unweighted) features of a database's poses using a given schema (cached).
func _index(db_path: String, schema_name: String) -> Dictionary:
	var cache_key := db_path + "|" + schema_name
	if indexed.has(cache_key):
		return indexed[cache_key]
	var db: Dictionary = databases[db_path]
	var schema: Dictionary = schemas[schema_name]
	var sr := float(schema["SampleRate"])
	var leaves: Array = schema["leaves"]
	var dims: int = schema["cardinality"]
	var ex: Dictionary = db.get("ExcludeFromDatabaseParameters", {"Min": 0.0, "Max": -0.3})
	var out := {
		"leaves": leaves, "dims": dims, "poses": 0, "rows": PackedFloat32Array(),
		"entry_clip": PackedStringArray(), "entry_loops": PackedByteArray(), "entry_disable": PackedByteArray(),
		"entry_length": PackedFloat32Array(), "pose_entry": PackedInt32Array(), "pose_time": PackedFloat32Array(),
		"pose_addend": PackedFloat32Array(), "pose_blocked": PackedByteArray(), "pose_cont": PackedFloat32Array(),
	}
	var half := PackedByteArray()
	half.resize(2)
	for e: Dictionary in db["entries"]:
		if not e.get("bEnabled", true):
			continue
		# A montage samples as its slot's one segment: the sequence played from AnimStartTime at
		# AnimPlayRate (every montage the databases use has a single segment). The montage's own
		# notifies (not the sequence's) drive exclusion and sampling ranges, as for any asset.
		# Pose times are stored in the sequence's time, which is what the matcher plays.
		var seq_asset: String = e["asset"]
		var seq_offset := 0.0   # sequence time = seq_offset + asset time * seq_rate
		var seq_rate := 1.0
		var asset_length := -1.0
		var notifies: Array = []
		if e["asset_type"] == "montage":
			var mm: Dictionary = montages.get(e["asset"], {})
			var segs: Array = []
			for slot: Dictionary in mm.get("slots", []):
				segs.append_array(slot["segments"])
			if segs.size() != 1 or mm.get("slots", []).size() != 1 or segs[0].get("asset_type") != "sequence":
				skipped.append("%s: %s (montage with %d segments)" % [db_path.get_file(), e["asset"], segs.size()])
				continue
			var seg: Dictionary = segs[0]
			seq_asset = seg["asset"]
			seq_rate = float(seg.get("AnimPlayRate", 1.0))
			seq_offset = float(seg.get("AnimStartTime", 0.0)) - float(seg.get("StartPos", 0.0)) * seq_rate
			asset_length = float(mm["length"])
			notifies = mm.get("notifies", [])
		elif e["asset_type"] == "multianim":
			if not _index_multianim(db_path, db, e, schema, out, half):
				skipped.append("%s: %s (multianim)" % [db_path.get_file(), e["asset"]])
			continue
		elif e["asset_type"] != "sequence":
			skipped.append("%s: %s (%s)" % [db_path.get_file(), e["asset"], e["asset_type"]])
			continue
		var s := _sampler(seq_asset)
		if s == null:
			skipped.append("%s: missing clip %s" % [db_path.get_file(), seq_asset])
			continue
		if e["asset_type"] == "sequence":
			notifies = sequences.get(e["asset"], {}).get("notifies", [])
			asset_length = s.length
		var asset_loops: bool = s.loops and e["asset_type"] == "sequence"
		var rng: Dictionary = e.get("SamplingRange", {"Min": 0.0, "Max": 0.0})
		var whole := float(rng["Min"]) == 0.0 and float(rng["Max"]) == 0.0
		var entry_loops := asset_loops and whole
		var lo := 0.0 if whole else float(rng["Min"])
		var hi := asset_length if whole else minf(asset_length, float(rng["Max"]))
		lo = minf(lo, hi)
		if not entry_loops:
			lo = maxf(lo, float(ex["Min"]))
			hi = minf(hi, asset_length + float(ex["Max"]))
		var ranges := [Vector2(lo, hi)]
		var sampling := []
		for n: Dictionary in notifies:
			if n.get("class") == "AnimNotifyState_PoseSearchExcludeFromDatabase":
				ranges = _subtract(ranges, float(n["time"]), float(n.get("end_time", n["time"])))
			elif n.get("class") == "AnimNotifyState_PoseSearchSamplingRange":
				sampling.append(Vector2(float(n["time"]), float(n.get("end_time", n["time"]))))
		if not sampling.is_empty():
			ranges = _intersect(ranges, _union(sampling))
		var entry: int = out["entry_clip"].size()
		out["entry_clip"].append(ANIMS + seq_asset + ".fbx")
		out["entry_loops"].append(1 if entry_loops else 0)
		out["entry_disable"].append(1 if e.get("bDisableReselection", false) else 0)
		out["entry_length"].append(s.length)
		var base_cost := float(db.get("BaseCostBias", 0.0))
		var looping_bias := float(db.get("LoopingCostBias", -0.005)) if asset_loops else 0.0
		for r: Vector2 in ranges:
			if r.y < r.x:
				continue
			var first := ceili(r.x * sr - 1e-4)
			var last := floori(r.y * sr + 1e-4)
			for i in range(first, last + 1):
				var asset_t := i / sr
				var t := seq_offset + asset_t * seq_rate
				var addend := base_cost
				var cont := NAN
				var blocked := 0
				for n: Dictionary in notifies:
					if not _active(n, asset_t):
						continue
					match n.get("class"):
						"AnimNotifyState_PoseSearchModifyCost":
							addend = float(n["object"]["properties"].get("CostAddend", -1.0))
						"AnimNotifyState_PoseSearchBlockTransition":
							blocked = 1
						"AnimNotifyState_PoseSearchOverrideContinuingPoseCostBias":
							cont = float(n["object"]["properties"].get("CostAddend", -1.0))
				addend += looping_bias
				half.encode_half(0, addend)
				out["pose_entry"].append(entry)
				out["pose_time"].append(t)
				out["pose_addend"].append(half.decode_half(0))
				out["pose_blocked"].append(blocked)
				out["pose_cont"].append(cont)
				out["rows"].append_array(_features(s, t, leaves, dims))
				out["poses"] += 1
	indexed[cache_key] = out
	return out


## One PoseSearchInteractionAsset entry: roles in the schema's skeleton order, each a one-segment
## montage played from the same asset time.
func _index_multianim(db_path: String, db: Dictionary, e: Dictionary, schema: Dictionary, out: Dictionary, half: PackedByteArray) -> bool:
	var psia: Dictionary = interactions.get(String(e["asset"]).get_file(), {})
	if psia.is_empty():
		return false
	var roles := {}  # role -> {sampler, origin, offset, rate}
	var asset_length := 0.0
	var notifies: Array = []
	for item: Dictionary in psia["Items"]:
		var mm: Dictionary = montages.get(item["asset"], {})
		var segs: Array = []
		for slot: Dictionary in mm.get("slots", []):
			segs.append_array(slot["segments"])
		if segs.size() != 1 or segs[0].get("asset_type") != "sequence":
			return false
		var seg: Dictionary = segs[0]
		var smp := _sampler(seg["asset"])
		if smp == null:
			return false
		var o: Dictionary = item["Origin"]
		var q: Array = o["rotation_xyzw"]
		var tr: Array = o["translation"]
		var rate := float(seg.get("AnimPlayRate", 1.0))
		roles[item["Role"]] = {
			"sampler": smp,
			"origin": Transform3D(Basis(Quaternion(-float(q[0]), float(q[1]), -float(q[2]), float(q[3])).normalized()),
				Vector3(float(tr[0]), -float(tr[1]), float(tr[2])) / UE_SCALE),
			"offset": float(seg.get("AnimStartTime", 0.0)) - float(seg.get("StartPos", 0.0)) * rate,
			"rate": rate,
		}
		asset_length = maxf(asset_length, float(mm["length"]))
		notifies.append_array(mm.get("notifies", []))
	var sr := float(schema["SampleRate"])
	var leaves: Array = schema["leaves"]
	var dims: int = schema["cardinality"]
	var ex: Dictionary = db.get("ExcludeFromDatabaseParameters", {"Min": 0.0, "Max": -0.3})
	var rng: Dictionary = e.get("SamplingRange", {"Min": 0.0, "Max": 0.0})
	var whole := float(rng["Min"]) == 0.0 and float(rng["Max"]) == 0.0
	var lo := 0.0 if whole else float(rng["Min"])
	var hi := asset_length if whole else minf(asset_length, float(rng["Max"]))
	lo = maxf(minf(lo, hi), float(ex["Min"]))
	hi = minf(hi, asset_length + float(ex["Max"]))
	var ranges := [Vector2(lo, hi)]
	var sampling := []
	for n: Dictionary in notifies:
		if n.get("class") == "AnimNotifyState_PoseSearchExcludeFromDatabase":
			ranges = _subtract(ranges, float(n["time"]), float(n.get("end_time", n["time"])))
		elif n.get("class") == "AnimNotifyState_PoseSearchSamplingRange":
			sampling.append(Vector2(float(n["time"]), float(n.get("end_time", n["time"]))))
	if not sampling.is_empty():
		ranges = _intersect(ranges, _union(sampling))
	var entry: int = out["entry_clip"].size()
	out["entry_clip"].append("psia:" + String(e["asset"]))
	out["entry_loops"].append(0)
	out["entry_disable"].append(1 if e.get("bDisableReselection", false) else 0)
	out["entry_length"].append(asset_length)
	var base_cost := float(db.get("BaseCostBias", 0.0))
	for r: Vector2 in ranges:
		if r.y < r.x:
			continue
		for i in range(ceili(r.x * sr - 1e-4), floori(r.y * sr + 1e-4) + 1):
			var t := i / sr
			var addend := base_cost
			var cont := NAN
			var blocked := 0
			for n: Dictionary in notifies:
				if not _active(n, t):
					continue
				match n.get("class"):
					"AnimNotifyState_PoseSearchModifyCost":
						addend = float(n["object"]["properties"].get("CostAddend", -1.0))
					"AnimNotifyState_PoseSearchBlockTransition":
						blocked = 1
					"AnimNotifyState_PoseSearchOverrideContinuingPoseCostBias":
						cont = float(n["object"]["properties"].get("CostAddend", -1.0))
			half.encode_half(0, addend)
			out["pose_entry"].append(entry)
			out["pose_time"].append(t)
			out["pose_addend"].append(half.decode_half(0))
			out["pose_blocked"].append(blocked)
			out["pose_cont"].append(cont)
			out["rows"].append_array(_multi_features(roles, t, leaves, dims))
			out["poses"] += 1
	return true


## Root of a role at asset time t: Origin * (root(0)^-1 * root(t)).
func _role_root(r: Dictionary, t: float) -> Transform3D:
	var smp: ClipSampler = r["sampler"]
	var root := _bone("root")
	var start := smp.bone(root, r["offset"])
	return (r["origin"] as Transform3D) * start.affine_inverse() * smp.bone(root, float(r["offset"]) + t * float(r["rate"]))


func _multi_features(roles: Dictionary, t: float, leaves: Array, dims: int) -> PackedFloat32Array:
	var row := PackedFloat32Array()
	row.resize(dims)
	for leaf: Dictionary in leaves:
		if leaf["type"] != "Position" or (leaf.get("bone") != "root" and leaf.get("bone") != null):
			continue
		var sample: Transform3D = _role_root(roles[leaf["SampleRole"]], t + float(leaf.get("SampleTimeOffset", 0.0)))
		var origin: Transform3D = _role_root(roles[leaf["OriginRole"]], t + float(leaf.get("OriginTimeOffset", 0.0)))
		var v := origin.affine_inverse() * sample.origin * UE_SCALE
		_encode(row, int(leaf["offset"]), v, leaf.get("ComponentStripping", {"name": "None"})["name"], false)
	return row


static func _subtract(ranges: Array, a: float, b: float) -> Array:
	var result := []
	for r: Vector2 in ranges:
		if b <= r.x or a >= r.y:
			result.append(r)
			continue
		if a > r.x:
			result.append(Vector2(r.x, a))
		if b < r.y:
			result.append(Vector2(b, r.y))
	return result


static func _union(ranges: Array) -> Array:
	var sorted := ranges.duplicate()
	sorted.sort_custom(func(a: Vector2, b: Vector2): return a.x < b.x)
	var result := []
	for r: Vector2 in sorted:
		if not result.is_empty() and r.x <= result[-1].y:
			result[-1] = Vector2(result[-1].x, maxf(result[-1].y, r.y))
		else:
			result.append(r)
	return result


static func _intersect(ranges: Array, other: Array) -> Array:
	var result := []
	for a: Vector2 in ranges:
		for b: Vector2 in other:
			var r := Vector2(maxf(a.x, b.x), minf(a.y, b.y))
			if r.y >= r.x:
				result.append(r)
	return result


static func _active(n: Dictionary, t: float) -> bool:
	if n.get("kind") != "state":
		return false
	var a := float(n["time"])
	var b := float(n.get("end_time", a))
	return a <= t + NOTIFY_HALF_INTERVAL and b >= t - NOTIFY_HALF_INTERVAL


# ---------------------------------------------------------------- features (spec section 2)

func _features(s: ClipSampler, t: float, leaves: Array, dims: int) -> PackedFloat32Array:
	var row := PackedFloat32Array()
	row.resize(dims)
	for leaf: Dictionary in leaves:
		var ts := t + float(leaf.get("SampleTimeOffset", 0.0))
		var to := t + float(leaf.get("OriginTimeOffset", 0.0))
		var b := _bone(leaf.get("bone"))
		var ob := _bone(leaf.get("origin_bone"))
		var strip: String = leaf.get("ComponentStripping", {"name": "None"})["name"]
		var v := Vector3.ZERO
		var normalize := false
		match leaf["type"]:
			"Position":
				v = _displacement(s, b, ob, ts, to)
				if leaf.get("bNormalizeDisplacement", false):
					v = v.limit_length(1.0)
			"Velocity":
				var to_prev := to - FINITE_DELTA if leaf.get("bUseCharacterSpaceVelocities", true) else to
				v = (_displacement(s, b, ob, ts, to) - _displacement(s, b, ob, ts - FINITE_DELTA, to_prev)) / FINITE_DELTA
				if leaf.get("bNormalize", false):
					v = v.limit_length(1.0)
			"Heading":
				var rel := s.bone(ob, to).basis.inverse() * s.bone(b, ts).basis
				var axis: String = leaf.get("HeadingAxis", {"name": "X"})["name"]
				v = rel.x if axis == "X" else (rel.y if axis == "Y" else rel.z)
				normalize = true
			"Curve":
				row[int(leaf["offset"])] = s.curve(leaf["CurveName"], ts)
				continue
			"Distance":
				row[int(leaf["offset"])] = _displacement(s, b, ob, ts, to).length()
				continue
			_:
				continue
		_encode(row, int(leaf["offset"]), v, strip, normalize)
	return row


## Bone position at ts relative to the origin at to, in the root's frame at to, in cm.
func _displacement(s: ClipSampler, b: int, ob: int, ts: float, to: float) -> Vector3:
	var root_xf := s.bone(_bone("root"), to)
	var p := s.bone(b, ts).origin
	if ob == _bone("root"):
		return root_xf.affine_inverse() * p * UE_SCALE
	return root_xf.basis.inverse() * (p - s.bone(ob, to).origin) * UE_SCALE


## Writes a vector with Unreal's component stripping (FeatureVectorHelper.cpp:25-84), where
## Unreal's Z is the root frame's up axis.
func _encode(row: PackedFloat32Array, offset: int, v: Vector3, strip: String, normalize: bool) -> void:
	var h0 := (up_axis + 1) % 3
	var h1 := (up_axis + 2) % 3
	if h0 > h1:
		var tmp := h0
		h0 = h1
		h1 = tmp
	match strip:
		"StripZ":
			var h := Vector2(v[h0], v[h1])
			if normalize and h.length_squared() > 1e-8:
				h = h.normalized()
			row[offset] = h.x
			row[offset + 1] = h.y
		"StripXY":
			var z := v[up_axis]
			if normalize and z * z > 1e-8:
				z = signf(z)
			row[offset] = z
		_:
			if normalize and v.length_squared() > 1e-8:
				v = v.normalized()
			row[offset] = v.x
			row[offset + 1] = v.y
			row[offset + 2] = v.z
