# CHT_GetUpMontages: rows filtered by MovementMode (OnGround) and
# RollingGetup, then a pose search (MaxNumberOfResults 1, output = montage start time) over the
# chooser's nested database PSD_GetUp with schema PSS_Ragdoll: trajectory positions at -0.5 s and 0,
# foot/hand positions and the pelvis X and Y axes, all in the root's frame, in cm. The database is
# indexed here from the four montages' PoseSearchSamplingRange windows at the schema's 30 Hz, with
# NormalizeWithCommonSchema weights (sqrt(w / sum w) / per-leaf mean deviation, min deviation 0.1).
extends RefCounted

const DATA := "res://extracted/data/"
const ANIMS := "res://extracted/anims/"
const CHOOSER := "CHT_GetUpMontages"
const SCHEMA := "PSS_Ragdoll"
const MIN_DEVIATION := 0.1
const UE_SCALE := 100.0
const BAKED := "res://databases/Ragdoll/CHT_GetUpMontages/PSD_GetUp.res"

## One per chooser row: {montage, clip (res path of the AnimationLibrary), rolling, movement_mode,
## end (montage play length), blend_in, blend_in_option, blend_in_curve, blend_out_window (Vector2),
## blend_out_time, poses: [[time, PackedFloat32Array features]]}
var rows: Array = []
var leaves: Array = []
var dims := 0
var weights := PackedFloat32Array()
## True when the poses come from the baked database rather than the index built here.
var baked := false
var _skeleton: Skeleton3D


func _init(skeleton: Skeleton3D) -> void:
	_skeleton = skeleton
	var choosers: Dictionary = JSON.parse_string(FileAccess.get_file_as_string(DATA + "choosers.json"))
	var montages: Dictionary = JSON.parse_string(FileAccess.get_file_as_string(DATA + "montages.json"))
	var schema: Dictionary = JSON.parse_string(FileAccess.get_file_as_string(DATA + "schemas.json"))[SCHEMA]
	leaves = schema["leaves"]
	dims = int(schema["cardinality"])
	var rate := float(schema["SampleRate"])
	var table: Dictionary = choosers[CHOOSER]["tables"][CHOOSER]
	var cols: Array = table["columns"]
	for r: Dictionary in table["rows"]:
		if r.get("disabled", false):
			continue
		var idx := int(r["index"])
		var key: String = r["result"]["asset"]
		var m: Dictionary = montages[key]
		var seg: Dictionary = m["slots"][0]["segments"][0]
		var row := {
			"montage": key.get_file(),
			"clip": ANIMS + String(seg["asset"]) + ".fbx",
			"movement_mode": "OnGround",
			"rolling": false,
			"end": float(seg["AnimEndTime"]),
			"blend_in": float(m["BlendIn"]["BlendTime"]),
			"blend_in_option": String(m["BlendIn"]["BlendOption"]["name"]),
			"blend_in_curve": m["BlendIn"].get("CustomCurve"),
			"blend_out_window": Vector2(-1, -1),
			"blend_out_time": 0.25,
			"poses": [],
		}
		for c: Dictionary in cols:
			var name: String = c["input"]["display_name"]
			var v: Dictionary = c["row_values"][idx]
			if name == "MovementMode":
				row["movement_mode"] = v["display_name"]
			elif name == "RollingGetup":
				row["rolling"] = v["name"] == "MatchTrue"
		var window := Vector2(0, float(seg["AnimEndTime"]))
		for n: Dictionary in m["notifies"]:
			if n["class"] == "AnimNotifyState_PoseSearchSamplingRange":
				window = Vector2(float(n["time"]), float(n["end_time"]))
			elif n["class"] == "BP_NotifyState_MontageBlendOut":
				var props: Dictionary = n["object"].get("properties", {})
				# BlendOutCondition NewEnumerator1 = WithMovementInput (the only one used here).
				if String(props.get("BlendOutCondition", "")) == "NewEnumerator1":
					row["blend_out_window"] = Vector2(float(n["time"]), float(n["end_time"]))
					row["blend_out_time"] = float(props.get("BlendOutTime", 0.2))
		var lib: AnimationLibrary = load(row["clip"])
		var anim := lib.get_animation(lib.get_animation_list()[0])
		var t := window.x
		while t <= window.y + 1e-4:
			row["poses"].append([t, _clip_features(anim, t)])
			t += 1.0 / rate
		rows.append(row)
	_compute_weights()
	_use_baked_database()


## The bake (tools/bake/bake_databases.gd) builds the chooser's nested PSD_GetUp too; when it is
## there its poses and weights are used, so the search matches the project's other databases.
func _use_baked_database() -> void:
	if not ResourceLoader.exists(BAKED):
		return
	var db: PoseDatabase = load(BAKED)
	if db.dims != dims:
		return
	for r: Dictionary in rows:
		var entry := db.entry_clip.find(r["clip"])
		if entry < 0:
			return
	for r: Dictionary in rows:
		var entry := db.entry_clip.find(r["clip"])
		var poses := []
		for p in db.pose_count():
			if db.pose_entry[p] != entry:
				continue
			var f := PackedFloat32Array()
			f.resize(dims)
			for d in dims:
				f[d] = db.raw_value(p, d)
			poses.append([db.pose_time[p], f])
		r["poses"] = poses
	weights = db.weights
	baked = true


# ------------------------------------------------------------------ features

func _clip_features(anim: Animation, t: float) -> PackedFloat32Array:
	var memo := {}
	var root := _clip_bone(anim, "root", t, memo)
	var f := PackedFloat32Array()
	f.resize(dims)
	for leaf: Dictionary in leaves:
		var off := int(leaf["offset"])
		var ts := t + float(leaf.get("SampleTimeOffset", 0.0))
		var v := Vector3.ZERO
		if leaf["type"] == "Position":
			if leaf["bone"] == "root":
				var r := _clip_root(anim, ts)
				v = root.affine_inverse() * r.origin * UE_SCALE
			else:
				v = root.affine_inverse() * _clip_bone(anim, leaf["bone"], t, memo).origin * UE_SCALE
		elif leaf["type"] == "Heading":
			var rel := root.basis.inverse() * _clip_bone(anim, leaf["bone"], t, memo).basis
			v = (rel.x if leaf["HeadingAxis"]["name"] == "X" else rel.y).normalized()
		f[off] = v.x
		f[off + 1] = v.y
		f[off + 2] = v.z
	return f


## Root bone before the clip's start: extrapolated from its first-frame velocity (the indexer's
## root extrapolation), clamped to the clip otherwise.
func _clip_root(anim: Animation, t: float) -> Transform3D:
	if t >= 0.0:
		return _clip_bone(anim, "root", minf(t, anim.length), {})
	var a := _clip_bone(anim, "root", 0.0, {})
	var b := _clip_bone(anim, "root", 1.0 / 30.0, {})
	return Transform3D(a.basis, a.origin + (a.origin - b.origin) * (-t * 30.0))


## Skeleton-space transform of a bone in a clip (forward kinematics of the local tracks).
func _clip_bone(anim: Animation, bone: String, t: float, memo: Dictionary) -> Transform3D:
	if memo.has(bone):
		return memo[bone]
	var i := _skeleton.find_bone(bone)
	var rest := _skeleton.get_bone_rest(i)
	var path := NodePath("Skeleton3D:" + bone)
	var pt := anim.find_track(path, Animation.TYPE_POSITION_3D)
	var rt := anim.find_track(path, Animation.TYPE_ROTATION_3D)
	var pos := anim.position_track_interpolate(pt, t) if pt >= 0 else rest.origin
	var rot := anim.rotation_track_interpolate(rt, t) if rt >= 0 else rest.basis.get_rotation_quaternion()
	var local := Transform3D(Basis(rot), pos)
	var p := _skeleton.get_bone_parent(i)
	var g := local if p < 0 else _clip_bone(anim, _skeleton.get_bone_name(p), t, memo) * local
	memo[bone] = g
	return g


## Query from the ragdoll: bone world transforms (name -> Transform3D), the capsule's root transform
## now (world) and its world position 0.5 s ago.
func query(bone_world: Dictionary, root_world: Transform3D, past_root_position: Vector3) -> PackedFloat32Array:
	var q := PackedFloat32Array()
	q.resize(dims)
	var inv := root_world.affine_inverse()
	for leaf: Dictionary in leaves:
		var off := int(leaf["offset"])
		var v := Vector3.ZERO
		if leaf["type"] == "Position":
			if leaf["bone"] == "root":
				v = inv * (past_root_position if float(leaf.get("SampleTimeOffset", 0.0)) < 0.0 else root_world.origin) * UE_SCALE
			else:
				v = inv * (bone_world[leaf["bone"]] as Transform3D).origin * UE_SCALE
		elif leaf["type"] == "Heading":
			var rel := root_world.basis.orthonormalized().inverse() * (bone_world[leaf["bone"]] as Transform3D).basis.orthonormalized()
			v = (rel.x if leaf["HeadingAxis"]["name"] == "X" else rel.y).normalized()
		q[off] = v.x
		q[off + 1] = v.y
		q[off + 2] = v.z
	return q


# Per-leaf deviation over every pose of the database (all four rows), NormalizeWithCommonSchema.
func _compute_weights() -> void:
	weights.resize(dims)
	var total := 0.0
	for leaf: Dictionary in leaves:
		total += float(leaf["Weight"]) * int(leaf["cardinality"])
	for leaf: Dictionary in leaves:
		var off := int(leaf["offset"])
		var card := int(leaf["cardinality"])
		var mean := Vector3.ZERO
		var count := 0
		for r: Dictionary in rows:
			for p: Array in r["poses"]:
				var f: PackedFloat32Array = p[1]
				mean += Vector3(f[off], f[off + 1], f[off + 2])
				count += 1
		mean /= maxf(count, 1)
		var dev := 0.0
		for r: Dictionary in rows:
			for p: Array in r["poses"]:
				var f: PackedFloat32Array = p[1]
				dev += (Vector3(f[off], f[off + 1], f[off + 2]) - mean).length()
		dev /= maxf(count, 1)
		if dev <= MIN_DEVIATION:
			dev = 1.0
		for i in card:
			weights[off + i] = sqrt(float(leaf["Weight"]) / total) / dev


## Evaluates the chooser: returns the row dictionary plus "time" and "cost", or {} when no row passes.
func choose(movement_mode: String, rolling_getup: bool, q: PackedFloat32Array) -> Dictionary:
	var best := {}
	var best_cost := INF
	for r: Dictionary in rows:
		if r["movement_mode"] != movement_mode or r["rolling"] != rolling_getup:
			continue
		for p: Array in r["poses"]:
			var f: PackedFloat32Array = p[1]
			var cost := 0.0
			for d in dims:
				var e := (f[d] - q[d]) * weights[d]
				cost += e * e
			if cost < best_cost:
				best_cost = cost
				best = r.duplicate()
				best["time"] = p[0]
				best["cost"] = cost
	return best
