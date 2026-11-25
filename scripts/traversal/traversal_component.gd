# Traversal (hurdle, vault, mantle, climb) as the Game Animation Sample's AC_TraversalLogic does it on
# the CMC character:
#   jump pressed -> TryTraversalAction: forward capsule sweep, ledges of the obstacle, room checks,
#   CHT_TraversalMontages_CMC (filter columns + pose search over its PSD_*_0 databases) -> montage
#   and start time -> PerformTraversalAction: play it in the matcher's action slot, Flying mode
#   (root motion moves the body, the obstacle is ignored), motion warping to the FrontLedge /
#   BackLedge / BackFloor targets inside the montage's warp windows, and the blend-out notify
#   (BP_NotifyState_MontageBlendOut) handing the body back to the movement component.
# There are no LevelBlock_Traversable actors: any body whose hit shape is a BoxShape3D (top face up)
# is traversable unless it has meta "traversable" = false. Its four top edges are the ledges, each
# with its outward horizontal normal, opposite edges paired, like the block's spline ledges.
# Units: the sample's values stay in cm (heights, depths, speeds, trace sizes); world positions are
# Godot metres, Unreal (x, y, z) = Godot (x, z, y).
# Use: player.add_component(preload("res://scripts/traversal/traversal_component.gd").new()).
extends Node

## Traces only see the world (layer 1), not the ragdoll's physical bones.
const WORLD_MASK := 1

signal traversal_started(result: Dictionary)
signal traversal_finished(result: Dictionary)

const CM := 0.01
const DATA := "res://extracted/data/"
const ANIMS := "res://extracted/anims/"
const DB_DIR := "res://databases/"
const CHOOSER := "CHT_TraversalMontages_CMC"
const MIN_LEDGE_WIDTH := 60.0            # LevelBlock_Traversable class default (cm)
const LEDGE_TIE_BREAK := 10.0            # FindLedgeClosestToActor: + up vector * 10
const CAPSULE_RADIUS := 30.0             # SandboxCharacter_CMC class defaults
const CAPSULE_HALF_HEIGHT := 86.0
## The CMC keeps the capsule hovering above the floor (MIN_FLOOR_DIST 1.9 .. MAX 2.4 cm), which is
## why the mesh sits at -88 under a 86 cm half height. Traces start from that capsule centre so the
## heights the chooser sees match the sample's (ObstacleHeight = ledge - floor - 2).
const FLOOR_GAP := 2.0
const FRONT_LEDGE_WARP_OFFSET := 0.5     # SetWarpTargets: FrontLedgeLocation + (0, 0, 0.5)
const BACK_FLOOR_DROP := 50.0            # floor check: back room - (0, 0, 50)
const ROOM_MARGIN := 2.0                 # (R + 2), (HH + 2)
## Deviation (no hand IK in the port): on a FrontLedge window, height the ledge has above what the
## clip was made for is added to the root in the LIFT_TIME before the hands reach the ledge instead of
## being spread over the window by the skew, so the hands don't plant inside the wall.
const LIFT_TIME := 0.25
const CLIP_SAMPLER := preload("res://tools/bake/clip_sampler.gd")

enum Action { NONE, HURDLE, VAULT, MANTLE }
const ACTION_NAMES := ["None", "Hurdle", "Vault", "Mantle"]
# E_MovementMode as the chooser's MultiEnum columns see it (CMC mapping, Get_PropertiesForTraversal).
enum Mode { ON_GROUND = 0, IN_AIR = 1, SLIDING = 2, TRAVERSING = 3, RAGDOLL = 4, FLYING = 5 }
# E_TraversalBlendOutCondition.
enum BlendOut { FORCE = 0, WITH_MOVEMENT_INPUT = 1, IF_FALLING = 2 }

## Set while a traversal montage plays (DoingTraversalAction).
var doing_traversal := false
## The last S_TraversalCheckResult (front/back ledges, floor, height, depth, chosen montage...).
var result := {}
## What the last TryTraversalAction returned: {traversal_check_failed, montage_selection_failed}.
var last_try := {}
## The sample's JustTraversed input: the montage's MovingTraversal curve. It is the curve value of
## the traversal montage from the moment it starts blending out until the blend-out time has passed,
## 0 otherwise (see report: JustTraversed = action not playing AND this > 0 AND |turn| <= 50).
var moving_traversal := 0.0
## Set by scripts to emulate holding the jump button (the Triggered event retries in the air).
var hold_jump := false
## Hand the montage's clip to motion matching as its continuing pose (see _continue_in_matcher).
var continue_in_from_traversal := true
## Montage time of the playing traversal (seconds), for debugging and tests.
var montage_time := 0.0
## Montage info of the playing (or last) traversal, see _montage_info().
var montage := {}

var player: Node
var character: GaspCharacter
var matcher: MotionMatcher

# Data shared by every instance (read once).
static var _choosers: Dictionary
static var _montages: Dictionary
static var _seq_curves := {}    # sequence asset -> {curve name -> [times, values]}
static var _dbs := {}           # db path -> PoseDatabase
static var _searches := {}      # db path -> PoseSearch
var _info_cache := {}           # montage asset -> info (uses this matcher's skeleton)
var _targets := {}              # warp target name -> {"pos": Vector3, "yaw": float}
var _hit_body: CollisionObject3D
var _end_mode := 0
var _blend_out_left := 0.0
var _last_velocity := Vector3.ZERO   # cm/s
# AnimatedDistanceFromFrontLedgeToBackLedge / ...ToBackFloor persist between traversals in the sample
# (hurdles without a BackLedge window reuse the previous value).
var _anim_dist_back_ledge := 0.0
var _anim_dist_back_floor := 0.0


func _ready() -> void:
	player = get_parent()
	if player.get("character") == null:
		await player.ready
	character = player.character
	matcher = player.matcher
	if _choosers.is_empty():
		_load_data()
	var clips := []
	for t: Dictionary in _choosers[CHOOSER]["tables"].values():
		for r: Dictionary in t["rows"]:
			var res: Dictionary = r["result"]
			if res.get("type") == "Asset" and _montages.has(res["asset"]):
				clips.append(_montage_info(res["asset"])["clip"])
	matcher.load_clips(clips)


static func _load_data() -> void:
	_choosers = JSON.parse_string(FileAccess.get_file_as_string(DATA + "choosers.json"))
	_montages = JSON.parse_string(FileAccess.get_file_as_string(DATA + "montages.json"))
	var seqs := {}
	for t: Dictionary in _choosers[CHOOSER]["tables"].values():
		for r: Dictionary in t["rows"]:
			var res: Dictionary = r["result"]
			if res.get("type") == "Asset" and _montages.has(res["asset"]):
				seqs[_montages[res["asset"]]["slots"][0]["segments"][0]["asset"]] = true
	# Only the distance_from_ledge curve is needed (SetWarpTargets); sequences.json is large, so it is
	# read once and only those curves are kept.
	var all: Dictionary = JSON.parse_string(FileAccess.get_file_as_string(DATA + "sequences.json"))
	for s: String in seqs:
		var curves := {}
		for c: Dictionary in all.get(s, {}).get("curves", []):
			curves[String(c["name"]).to_lower()] = [PackedFloat32Array(c["times"]), PackedFloat32Array(c["values"])]
		_seq_curves[s] = curves
	all = {}
	for t: Dictionary in _choosers[CHOOSER]["tables"].values():
		for col: Dictionary in t["columns"]:
			if col.get("type") != "PoseSearchColumn":
				continue
			for cell in col.get("row_values", []):
				if cell is Dictionary and cell.has("database"):
					_load_db(cell["database"])


static func _load_db(path: String) -> void:
	if _dbs.has(path):
		return
	var file: String = DB_DIR + path.replace(":", "/") + ".res"
	if not ResourceLoader.exists(file):
		push_warning("traversal database not built: " + file)
		return
	var db: PoseDatabase = load(file)
	_dbs[path] = db
	var s := PoseSearch.new()
	s.set_database(db.values, db.dims, db.weights, db.pose_addend, db.pose_blocked, db.pose_entry)
	_searches[path] = s


# ------------------------------------------------------------------ player hooks

## IA_Jump Started: traversal first; the plain jump runs only when the check or the montage
## selection failed. While a montage plays (CanPerformJumpAction false) the press does nothing.
func on_jump_pressed() -> bool:
	if character.is_sliding():  # the Mover pawn: jump while sliding only uncrouches
		character.jump()
		return true
	if not _can_perform_jump_action():
		return true
	var r := try_traversal_action(get_traversal_check_inputs())
	return not (r["traversal_check_failed"] or r["montage_selection_failed"])


func override_movement(dt: float) -> bool:
	if doing_traversal:
		# Root motion moves the body (after the pose is sampled, see after_animation). Keep the
		# acceleration current for the trajectory and the blend-out condition.
		var input3 := Vector3(character.move_input.x, 0, character.move_input.y)
		character.acceleration_cm = input3.normalized() * character.max_acceleration * clampf(input3.length(), 0.0, 1.0) if input3.length() > 0.0 else Vector3.ZERO
		return true
	# IA_Jump Triggered: every frame the button is held, retry (catches ledges in the air).
	var held := hold_jump or (InputMap.has_action("jump") and Input.is_action_pressed("jump"))
	if held and _can_perform_jump_action() and character.movement_mode == GaspCharacter.MovementMode.IN_AIR:
		try_traversal_action(get_traversal_check_inputs())
		if doing_traversal:
			return true
	return false


func after_animation(dt: float) -> void:
	if _blend_out_left > 0.0:
		_blend_out_left -= dt
		if _blend_out_left <= 0.0:
			moving_traversal = 0.0
	if not doing_traversal:
		return
	var t_now := matcher.blend.get_current_time()
	_apply_root_motion(montage_time, t_now, dt)
	montage_time = t_now
	if _should_blend_out(t_now):
		_on_blend_out()


func _can_perform_jump_action() -> bool:
	return not doing_traversal and matcher.action_clip == ""


# ------------------------------------------------------------------ check inputs (3.2)

## GetTraversalCheckInputs (SandboxCharacter_CMC), by movement mode.
func get_traversal_check_inputs() -> Dictionary:
	var fwd := character.forward()
	if character.movement_mode == GaspCharacter.MovementMode.ON_GROUND:
		var local_x := character.velocity_cm.dot(fwd)
		return {"forward": fwd, "distance": _map_clamped(local_x, 0, 500, 75, 350),
			"origin_offset": Vector3.ZERO, "end_offset": Vector3.ZERO, "radius": 30.0, "half_height": 60.0}
	return {"forward": fwd, "distance": 75.0, "origin_offset": Vector3.ZERO,
		"end_offset": Vector3(0, 50, 0), "radius": 30.0, "half_height": 86.0}


# ------------------------------------------------------------------ TryTraversalAction (3.3)

func try_traversal_action(inputs: Dictionary) -> Dictionary:
	var failed := {"traversal_check_failed": true, "montage_selection_failed": false}
	last_try = failed
	var space := character.get_world_3d().direct_space_state
	var a := _actor_location()
	var r := CAPSULE_RADIUS
	var hh := CAPSULE_HALF_HEIGHT
	var r0 := {"action": Action.NONE, "has_front_ledge": false, "front_ledge": Vector3.ZERO, "front_normal": Vector3.ZERO,
		"has_back_ledge": false, "back_ledge": Vector3.ZERO, "back_normal": Vector3.ZERO, "has_back_floor": false,
		"back_floor": Vector3.ZERO, "obstacle_height": 0.0, "obstacle_depth": 0.0, "back_ledge_height": 0.0,
		"hit_body": null, "montage": "", "start_time": 0.0, "play_rate": 1.0, "step": "forward trace"}
	result = r0

	# 2.1 forward sweep.
	var start: Vector3 = a + inputs["origin_offset"] * CM
	var end: Vector3 = start + inputs["forward"] * float(inputs["distance"]) * CM + inputs["end_offset"] * CM
	var hit := _capsule_trace(space, start, end, inputs["radius"], inputs["half_height"])
	if not hit["hit"]:
		return failed
	var box := _traversable_box(hit)
	if box.is_empty():
		r0["step"] = "not traversable"
		return failed
	r0["hit_body"] = hit["collider"]
	# 2.2 ledges.
	_get_ledge_transforms(box, hit["point"], a, r0)

	# 3.1 / 3.2 room to reach the front ledge.
	r0["step"] = "front ledge"
	if not r0["has_front_ledge"]:
		return failed
	var exclude := [character.get_rid()]
	var front_room: Vector3 = r0["front_ledge"] + r0["front_normal"] * (r + ROOM_MARGIN) * CM + Vector3(0, hh + ROOM_MARGIN, 0) * CM
	var t := _capsule_trace(space, a, front_room, r, hh, exclude)
	if t["hit"] or t["initial"]:
		r0["has_front_ledge"] = false
		r0["step"] = "no room at front ledge"
		return failed
	# 3.3 ledge height above the feet.
	r0["obstacle_height"] = absf((a.y / CM - hh) - r0["front_ledge"].y / CM)
	# 3.4 room across the top.
	var back_room: Vector3 = r0["back_ledge"] + r0["back_normal"] * (r + ROOM_MARGIN) * CM + Vector3(0, hh + ROOM_MARGIN, 0) * CM
	var top := _capsule_trace(space, front_room, back_room, r, hh, exclude)
	if not top["hit"]:
		r0["obstacle_depth"] = _xy(r0["front_ledge"] - r0["back_ledge"]).length() / CM
		# 3.6 floor behind.
		var floor_end: Vector3 = r0["back_ledge"] + r0["back_normal"] * (r + ROOM_MARGIN) * CM - Vector3(0, BACK_FLOOR_DROP, 0) * CM
		var fl := _capsule_trace(space, back_room, floor_end, r, hh, exclude)
		if fl["hit"]:
			r0["has_back_floor"] = true
			r0["back_floor"] = fl["point"]
			r0["back_ledge_height"] = absf(fl["point"].y - r0["back_ledge"].y) / CM
		else:
			r0["has_back_floor"] = false
	else:
		r0["obstacle_depth"] = _xy(top["point"] - r0["front_ledge"]).length() / CM
		r0["has_back_ledge"] = false

	# 4.1 interaction transform (front ledge, Z along the ledge normal) for the pose search.
	# 4.2 chooser.
	r0["step"] = "chooser"
	var props := _properties_for_traversal()
	var ctx := {
		"ActionType": Action.NONE, "HasFrontLedge": r0["has_front_ledge"], "HasBackLedge": r0["has_back_ledge"],
		"HasBackFloor": r0["has_back_floor"], "ObstacleHeight": r0["obstacle_height"], "ObstacleDepth": r0["obstacle_depth"],
		"BackLedgeHeight": r0["back_ledge_height"],
		"DistanceToLedge": (r0["front_ledge"] - character.global_position).length() / CM,
		"MovementMode": props["movement_mode"], "Gait": props["gait"], "Speed": props["speed"],
	}
	var chosen := _evaluate_chooser(ctx, r0["front_ledge"], r0["front_normal"])
	r0["chooser"] = chosen
	if chosen.is_empty():
		last_try = {"traversal_check_failed": false, "montage_selection_failed": true}
		r0["step"] = "no montage"
		return last_try
	r0["action"] = chosen["action"]
	r0["montage"] = chosen["montage"]
	r0["start_time"] = chosen["start_time"]
	r0["play_rate"] = 1.0
	# 5.
	if r0["action"] == Action.NONE:
		r0["step"] = "action none"
		return failed
	r0["step"] = "performing"
	_perform_traversal_action(r0)
	last_try = {"traversal_check_failed": false, "montage_selection_failed": false}
	return last_try


## Capsule centre the way the sample's CMC holds it: FLOOR_GAP above the mesh root (the feet).
func _actor_location() -> Vector3:
	return character.global_position + Vector3(0, (CAPSULE_HALF_HEIGHT + FLOOR_GAP) * CM, 0)


func _properties_for_traversal() -> Dictionary:
	var mode := Mode.ON_GROUND if character.movement_mode == GaspCharacter.MovementMode.ON_GROUND else Mode.IN_AIR
	return {"movement_mode": mode, "gait": character.gait, "speed": character.speed_2d()}


# CapsuleTraceSingle: UE half height includes the hemispheres, like Godot's capsule height / 2.
func _capsule_trace(space: PhysicsDirectSpaceState3D, from: Vector3, to: Vector3, radius_cm: float, half_height_cm: float, exclude := []) -> Dictionary:
	var shape := CapsuleShape3D.new()
	shape.radius = radius_cm * CM
	shape.height = maxf(half_height_cm * 2.0, radius_cm * 2.0) * CM
	var q := PhysicsShapeQueryParameters3D.new()
	q.shape = shape
	q.transform = Transform3D(Basis.IDENTITY, from)
	q.margin = 0.0
	q.exclude = exclude if not exclude.is_empty() else [character.get_rid()]
	q.collision_mask = WORLD_MASK  # not the ragdoll's bodies (layer 10)
	var out := {"hit": false, "initial": false, "point": to, "normal": Vector3.ZERO, "collider": null, "shape": -1, "location": to}
	if not space.intersect_shape(q, 1).is_empty():
		var info := space.get_rest_info(q)
		out.merge({"hit": true, "initial": true, "location": from, "point": info.get("point", from),
			"normal": info.get("normal", Vector3.ZERO), "collider": instance_from_id(info["collider_id"]) if info.has("collider_id") else null,
			"shape": info.get("shape", -1)}, true)
		return out
	q.motion = to - from
	var frac := space.cast_motion(q)
	if frac[1] >= 1.0:
		return out
	q.transform.origin = from + q.motion * frac[1]
	q.motion = Vector3.ZERO
	var info := space.get_rest_info(q)
	if info.is_empty():
		return out
	out.merge({"hit": true, "location": from + (to - from) * frac[0], "point": info["point"], "normal": info["normal"],
		"collider": instance_from_id(info["collider_id"]), "shape": info["shape"]}, true)
	return out


## The obstacle's box: {xf: shape global transform (scale removed), half: half extents in m}. Empty when
## the hit is not a box (not "LevelBlock_Traversable").
func _traversable_box(hit: Dictionary) -> Dictionary:
	var body = hit["collider"]
	if not (body is CollisionObject3D) or (body as Object).get_meta("traversable", true) == false:
		return {}
	var owner_id: int = body.shape_find_owner(hit["shape"])
	var node = body.shape_owner_get_owner(owner_id)
	if not (node is CollisionShape3D) or not ((node as CollisionShape3D).shape is BoxShape3D):
		return {}
	var xf: Transform3D = (node as Node3D).global_transform
	var scale := xf.basis.get_scale()
	var half: Vector3 = ((node as CollisionShape3D).shape as BoxShape3D).size * 0.5 * scale
	return {"xf": Transform3D(xf.basis.orthonormalized(), xf.origin), "half": half}


## LevelBlock_Traversable.GetLedgeTransforms on a box: ledges are the 4 top edges with outward
## normals; 1<->2 and 3<->4 are opposite.
func _get_ledge_transforms(box: Dictionary, hit_location: Vector3, actor: Vector3, r0: Dictionary) -> void:
	var xf: Transform3D = box["xf"]
	var h: Vector3 = box["half"]
	var ledges := []
	for axis: int in [0, 2]:
		for sgn: float in [1.0, -1.0]:
			var n_local := Vector3.ZERO
			n_local[axis] = sgn
			var along := 2 - axis  # the other horizontal axis
			var a_local := Vector3(0, h.y, 0)
			a_local[axis] = sgn * h[axis]
			var b_local := a_local
			a_local[along] = -h[along]
			b_local[along] = h[along]
			ledges.append({"a": xf * a_local, "b": xf * b_local, "n": (xf.basis * n_local).normalized()})
	var opposite := {0: 1, 1: 0, 2: 3, 3: 2}
	var best := -1
	var best_d := INF
	for i in ledges.size():
		var l: Dictionary = ledges[i]
		var d: float = (_closest_on_segment(l["a"], l["b"], actor) + l["n"] * LEDGE_TIE_BREAK * CM - actor).length()
		if d < best_d:
			best_d = d
			best = i
	var closest: Dictionary = ledges[best]
	var length: float = (closest["b"] - closest["a"]).length() / CM
	if length < MIN_LEDGE_WIDTH:
		r0["has_front_ledge"] = false
		return
	var dir: Vector3 = (closest["b"] - closest["a"]).normalized()
	var along_hit: float = (_closest_on_segment(closest["a"], closest["b"], hit_location) - closest["a"]).length() / CM
	var d := clampf(along_hit, MIN_LEDGE_WIDTH / 2.0, length - MIN_LEDGE_WIDTH / 2.0)
	r0["has_front_ledge"] = true
	r0["front_ledge"] = closest["a"] + dir * d * CM
	r0["front_normal"] = closest["n"]
	var opp: Dictionary = ledges[opposite[best]]
	r0["has_back_ledge"] = true
	r0["back_ledge"] = _closest_on_segment(opp["a"], opp["b"], r0["front_ledge"])
	r0["back_normal"] = opp["n"]


static func _closest_on_segment(a: Vector3, b: Vector3, p: Vector3) -> Vector3:
	var ab := b - a
	var t := clampf((p - a).dot(ab) / maxf(ab.length_squared(), 1e-12), 0.0, 1.0)
	return a + ab * t


static func _xy(v: Vector3) -> Vector2:
	return Vector2(v.x, v.z)


# ------------------------------------------------------------------ chooser (3.5)

## CHT_TraversalMontages_CMC: root table (first passing row whose nested table gives a montage), the
## nested table's filter columns, then its PoseSearchColumn picks the row and start time with the
## lowest cost over the rows left (MaxNumberOfResults 1).
func _evaluate_chooser(ctx: Dictionary, ledge: Vector3, normal: Vector3) -> Dictionary:
	var entry: Dictionary = _choosers[CHOOSER]
	var root_table: Dictionary = entry["tables"][entry["root_table"]]
	for index in _filter_rows(root_table, ctx):
		var row: Dictionary = root_table["rows"][index]
		var action := Action.NONE
		for col: Dictionary in root_table["columns"]:
			if col.get("type") == "OutputEnumColumn" and not col.get("bDisabled", false):
				action = int(col["row_values"][index]["value"])
		var res: Dictionary = row["result"]
		if res.get("type") != "NestedChooser":
			continue
		var pick := _evaluate_nested(entry["tables"][res["chooser"]], ctx, ledge, normal)
		if pick.is_empty():
			continue
		pick["action"] = action
		pick["root_row"] = index
		return pick
	return {}


func _evaluate_nested(table: Dictionary, ctx: Dictionary, ledge: Vector3, normal: Vector3) -> Dictionary:
	var rows := _filter_rows(table, ctx)
	if rows.is_empty():
		return {}
	var ps_col := {}
	for col: Dictionary in table["columns"]:
		if col.get("type") == "PoseSearchColumn" and not col.get("bDisabled", false):
			ps_col = col
	if ps_col.is_empty():
		var res: Dictionary = table["rows"][rows[0]]["result"]
		return {"montage": res["asset"], "start_time": 0.0, "row": rows[0], "cost": 0.0}
	var db_path: String = ps_col["row_values"][rows[0]]["database"]
	if not _dbs.has(db_path):
		return {}
	var db: PoseDatabase = _dbs[db_path]
	var q := _query(db, ledge, normal)
	var wq: PackedFloat32Array = _searches[db_path].weigh(q)
	var best := {}
	var best_cost := INF
	for index in rows:
		var cell: Dictionary = ps_col["row_values"][index]
		var entry := _entry_of_row(ps_col, index)
		if entry < 0 or entry >= db.entry_clip.size():
			continue
		if db.entry_clip[entry] != _montage_info(cell["entry"]["asset"])["clip"]:
			push_warning("traversal: %s entry %d is not %s (rebuild the databases)" % [db_path, entry, cell["entry"]["asset"]])
			continue
		for p in db.pose_count():
			if db.pose_entry[p] != entry:
				continue
			var cost: float = _searches[db_path].feature_cost(p, wq) + db.pose_addend[p]
			if cost < best_cost:
				best_cost = cost
				best = {"montage": cell["entry"]["asset"], "start_time": db.pose_time[p], "row": index, "cost": cost, "pose": p, "db": db_path}
	return best


## The database entry of a PoseSearchColumn row: the baker adds the column's row entries in order.
func _entry_of_row(ps_col: Dictionary, index: int) -> int:
	var entry := -1
	for i in index + 1:
		var cell = ps_col["row_values"][i]
		if cell is Dictionary and cell.get("entry") is Dictionary and cell["entry"].get("asset") != null:
			entry += 1
	return entry


func _filter_rows(table: Dictionary, ctx: Dictionary) -> Array:
	var rows := []
	for r: Dictionary in table["rows"]:
		if not r.get("disabled", false):
			rows.append(int(r["index"]))
	for col: Dictionary in table["columns"]:
		if col.get("bDisabled", false) or col.get("is_output", false):
			continue
		var type: String = col["type"]
		if type == "PoseSearchColumn":
			continue
		var key: String = col["input"]["property_chain_friendly"][0]
		if not ctx.has(key):
			continue
		var values: Array = col.get("row_values", [])
		var kept := []
		for index in rows:
			if index >= values.size():
				continue
			var cell = values[index]
			var ok := true
			if type == "MultiEnumColumn":
				ok = (int(cell["mask"]) & (1 << int(ctx[key]))) != 0
			else:
				ok = ChooserEvaluator._passes(type, cell, ctx[key], col)
			if ok:
				kept.append(index)
		rows = kept
	return rows


## PSS_Traversal_Chooser query: trajectory and feet from the character (the matcher's query code), and
## the two PSC_Traversal channels from the interaction transform: the front ledge's position and the
## X axis of MakeRotFromZ(FrontLedgeNormal) (Unreal Up x N, which is N x Up in Godot's axes), both in
## the root's frame.
func _query(db: PoseDatabase, ledge: Vector3, normal: Vector3) -> PackedFloat32Array:
	var row: PackedFloat32Array = matcher._query(db, {}, null, -1)
	var root_basis: Basis = matcher._root_basis(0.0)
	var root_pos: Vector3 = matcher.trajectory.sample_at(0.0)[0]
	var ledge_x := normal.cross(Vector3.UP).normalized()
	for leaf: Dictionary in db.leaves:
		var off := int(leaf["offset"])
		var cls: String = leaf.get("class", "")
		if cls == "PSC_Traversal_Pos_C":
			var v := root_basis.inverse() * (ledge - root_pos) / CM
			row[off] = v.x
			row[off + 1] = v.y
			row[off + 2] = v.z
		elif cls == "PSC_Traversal_Head_C":
			var h := (root_basis.inverse() * ledge_x).normalized()
			row[off] = h.x
			row[off + 1] = h.y
			row[off + 2] = h.z
	return row


# ------------------------------------------------------------------ PerformTraversalAction (3.6, 3.7)

func _perform_traversal_action(r0: Dictionary) -> void:
	montage = _montage_info(r0["montage"])
	result = r0
	doing_traversal = true
	montage_time = r0["start_time"]
	_set_warp_targets(r0)
	_hit_body = r0["hit_body"]
	if _hit_body is PhysicsBody3D:
		character.add_collision_exception_with(_hit_body)
	# Flying: no gravity, root motion drives. The CMC reports Flying as InAir to the anim graph.
	character.movement_mode = GaspCharacter.MovementMode.IN_AIR
	_end_mode = GaspCharacter.MovementMode.IN_AIR if r0["action"] == Action.VAULT else GaspCharacter.MovementMode.ON_GROUND
	_last_velocity = character.velocity_cm
	moving_traversal = 0.0
	_blend_out_left = 0.0
	matcher.play_action(montage["clip"], r0["start_time"], montage["length"], montage["blend_in"], r0["play_rate"])
	traversal_started.emit(r0)


## SetWarpTargets: FrontLedge (attach bone onto the ledge, facing it), and for hurdles and vaults the
## BackLedge, and for hurdles the BackFloor target, from the Distance_From_Ledge curve at the end of
## their first windows.
func _set_warp_targets(r0: Dictionary) -> void:
	_targets.clear()
	_targets["FrontLedge"] = {"pos": r0["front_ledge"] + Vector3(0, FRONT_LEDGE_WARP_OFFSET * CM, 0),
		"x_axis": r0["front_normal"].cross(Vector3.UP).normalized()}
	var action: int = r0["action"]
	if action == Action.HURDLE or action == Action.VAULT:
		var w := _first_window("BackLedge")
		if not w.is_empty():
			_anim_dist_back_ledge = _curve("distance_from_ledge", w["end"])
			_targets["BackLedge"] = {"pos": r0["back_ledge"]}
	if action == Action.HURDLE:
		var w := _first_window("BackFloor")
		if not w.is_empty():
			_anim_dist_back_floor = _curve("distance_from_ledge", w["end"])
			var p: Vector3 = r0["back_ledge"] + r0["back_normal"] * absf(_anim_dist_back_ledge - _anim_dist_back_floor) * CM
			_targets["BackFloor"] = {"pos": Vector3(p.x, r0["back_floor"].y, p.z)}


func _first_window(target: String) -> Dictionary:
	for w: Dictionary in montage["windows"]:
		if w["target"] == target:
			return w
	return {}


func _curve(name: String, t: float) -> float:
	var curves: Dictionary = _seq_curves.get(montage["sequence"], {})
	if not curves.has(name):
		return 0.0
	var times: PackedFloat32Array = curves[name][0]
	var vals: PackedFloat32Array = curves[name][1]
	var i := times.bsearch(t)
	if i <= 0:
		return vals[0]
	if i >= times.size():
		return vals[-1]
	return lerpf(vals[i - 1], vals[i], (t - times[i - 1]) / maxf(times[i] - times[i - 1], 1e-9))


# ------------------------------------------------------------------ root motion and warping

## Moves the body by the montage's root motion from t0 to t1 (montage = sequence time), skew-warped
## inside the warp windows (RootMotionModifier_SkewWarp), and turns it (rotation warp, FrontLedge).
## Montage root motion is not weighted by the blend-in (RootMotionFromMontagesOnly).
func _apply_root_motion(t0: float, t1: float, dt: float) -> void:
	if t1 <= t0:
		_place_visual()
		return
	var cuts := [t0, t1]
	for w: Dictionary in montage["windows"]:
		for b in [w["start"], w["end"]]:
			if b > t0 and b < t1:
				cuts.append(b)
	cuts.sort()
	var moved := Vector3.ZERO
	for i in cuts.size() - 1:
		var a: float = cuts[i]
		var b: float = cuts[i + 1]
		if b - a < 1e-6:
			continue
		var w := _window_at(a)
		var step := _root_delta(a, b)          # [position (root-local, m), yaw]
		var frame := _root_frame()
		var d: Vector3 = frame * step[0]
		var turn: float = step[1]
		if not w.is_empty() and _targets.has(w["target"]):
			var rem := _root_delta(a, w["end"])
			var r: Vector3 = frame * rem[0]
			var target := _window_target(w)
			var to_target: Vector3 = target["pos"] - character.global_position
			if w["ignore_z"]:
				to_target.y = r.y
			var extra: float = to_target.y - r.y   # height the clip lacks to reach the target
			var contact: float = w.get("contact", -1.0)
			if w["bone"] != "" and contact > a and extra > 0.0:
				var flat := Vector3(to_target.x, r.y, to_target.z)
				d = _skew_warp(d, r, flat)
				var lift_from := maxf(w["start"], contact - LIFT_TIME)
				if b > lift_from:
					var from := maxf(a, lift_from)
					d.y += extra * clampf((b - from) / maxf(contact - from, 1e-6), 0.0, 1.0)
			else:
				d = _skew_warp(d, r, to_target)
			if w["rotation"] and target.has("yaw"):
				var time_left: float = (w["end"] - a) * w["rotation_time_multiplier"]
				var alpha := clampf((b - a) / maxf(time_left, 1e-6), 0.0, 1.0)
				var target_rel := wrapf(target["yaw"] - character.yaw, -PI, PI)
				turn += alpha * wrapf(target_rel - rem[1], -PI, PI)
		character.global_position += d
		character.yaw = wrapf(character.yaw + turn, -PI, PI)
		moved += d
	if dt > 0.0:
		character.velocity_cm = moved / dt / CM
		character.velocity = moved / dt
	_last_velocity = character.velocity_cm
	_place_visual()


## OffsetRoot is released while the slot plays: the visual root follows the capsule.
func _place_visual() -> void:
	matcher.visual_yaw = character.yaw
	matcher.visual.global_position = character.global_position
	matcher.visual.global_basis = Basis(Vector3.UP, character.yaw)


## Root-local (the clip root's frame) to world, at the capsule's yaw.
func _root_frame() -> Basis:
	return Basis(Vector3.UP, character.yaw) * Mannequin.SKELETON_TURN


func _window_at(t: float) -> Dictionary:
	var found := {}
	for w: Dictionary in montage["windows"]:
		if t >= w["start"] - 1e-6 and t < w["end"]:
			found = w  # overlapping windows: the later one
	return found


## Where the root must be at the window's end: for a bone warp point the root is placed so the bone
## (attach) lands on the target with its X axis along the ledge; otherwise the root itself.
func _window_target(w: Dictionary) -> Dictionary:
	var target: Dictionary = _targets[w["target"]]
	if w["bone"] == "":
		return {"pos": target["pos"]}
	var rel: Transform3D = w["bone_rel"]  # bone in the root's frame at the window's end
	var bone_x_root := Mannequin.SKELETON_TURN * rel.basis.x  # at yaw 0
	var want: Vector3 = target["x_axis"]
	# Basis(UP, yaw) adds yaw to atan2(x, z): turn so the bone's X axis points along the ledge.
	var yaw := wrapf(atan2(want.x, want.z) - atan2(bone_x_root.x, bone_x_root.z), -PI, PI)
	var pos: Vector3 = target["pos"] - Basis(Vector3.UP, yaw) * Mannequin.SKELETON_TURN * rel.origin
	return {"pos": pos, "yaw": yaw}


## SkewWarp's translation: the delta's component along the remaining root motion is scaled and sheared
## so the remaining motion ends on the target; the perpendicular part is kept.
static func _skew_warp(delta: Vector3, remaining: Vector3, to_target: Vector3) -> Vector3:
	var rlen := remaining.length()
	if delta.is_zero_approx():
		return Vector3.ZERO
	if rlen < 1e-5:
		return delta
	var axis := remaining / rlen
	var along := delta.dot(axis)
	return delta - axis * along + to_target * (along / rlen)


## Root motion between two clip times: [translation in the root's frame at t0 (m), yaw turn].
func _root_delta(t0: float, t1: float) -> Array:
	var a := _root_at(t0)
	var b := _root_at(t1)
	var rel := a.affine_inverse() * b
	var q := rel.basis.get_rotation_quaternion()
	return [rel.origin, 2.0 * atan2(q.z, q.w)]


func _root_at(t: float) -> Transform3D:
	var anim: Animation = montage["anim"]
	var tc := clampf(t, 0.0, anim.length)
	var pos := Vector3.ZERO if montage["root_pos"] < 0 else anim.position_track_interpolate(montage["root_pos"], tc)
	var rot := Quaternion.IDENTITY if montage["root_rot"] < 0 else anim.rotation_track_interpolate(montage["root_rot"], tc)
	return Transform3D(Basis(rot), pos)


func _bone_local_at(anim: Animation, pos_track: int, rot_track: int, rest: Transform3D, t: float) -> Transform3D:
	var pos := rest.origin if pos_track < 0 else anim.position_track_interpolate(pos_track, t)
	var rot := rest.basis.get_rotation_quaternion() if rot_track < 0 else anim.rotation_track_interpolate(rot_track, t)
	return Transform3D(Basis(rot), pos)


# ------------------------------------------------------------------ blend out (3.9)

func _should_blend_out(t: float) -> bool:
	var n: Dictionary = montage["blend_out_notify"]
	if not n.is_empty() and t >= n["start"] and t <= n["end"]:
		match int(n["condition"]):
			BlendOut.FORCE:
				return true
			BlendOut.WITH_MOVEMENT_INPUT:
				if not character.acceleration_cm.is_zero_approx():
					return true
			BlendOut.IF_FALLING:
				if character.movement_mode == GaspCharacter.MovementMode.IN_AIR:
					return true
	# Montage auto blend-out: BlendOutTriggerTime < 0 starts it BlendOut.BlendTime before the end.
	if montage["auto_blend_out"]:
		var trigger: float = montage["blend_out_trigger"]
		var at: float = montage["length"] - (montage["blend_out_time"] if trigger < 0.0 else trigger)
		if t >= at - 1e-4:
			return true
	return t >= montage["length"] - 1e-4


## OnBlendOut: back to Walking (Falling after a vault), stop ignoring the obstacle, hand the pose back
## to motion matching.
func _on_blend_out() -> void:
	doing_traversal = false
	if _hit_body is PhysicsBody3D and is_instance_valid(_hit_body):
		character.remove_collision_exception_with(_hit_body)
	_hit_body = null
	character.movement_mode = _end_mode
	if _end_mode == GaspCharacter.MovementMode.ON_GROUND:
		character.velocity_cm.y = 0.0
	character.velocity = character.velocity_cm * CM
	var n: Dictionary = montage["blend_out_notify"]
	var blend_time: float = n["time"] if not n.is_empty() and montage_time >= n["start"] else montage["blend_out_time"]
	moving_traversal = montage["moving_traversal"]
	_blend_out_left = blend_time if moving_traversal > 0.0 else 0.0
	result["blend_out_time"] = montage_time
	matcher.stop_action()
	if continue_in_from_traversal:
		_continue_in_matcher()
	traversal_finished.emit(result)


## Lets motion matching treat the montage's clip, at the hand-back time, as its continuing pose when a
## database it searches holds that clip there (the sample's *_FromTraversal databases hold the
## traversal sequences' ends). Without this the hand-back is always a fresh search and a cross-fade.
func _continue_in_matcher() -> void:
	var t := matcher.blend.get_current_time()
	var paths: Array = matcher.databases.keys()
	paths.sort()
	for path: String in paths:
		if not "FromTraversal" in path:
			continue
		var db: PoseDatabase = matcher.databases[path]
		var entry := db.entry_clip.find(montage["clip"])
		if entry < 0:
			continue
		var pose := db.pose_index(entry, t)
		if pose < 0:
			continue
		matcher.current_db = path
		matcher.current_pose = pose
		return


# ------------------------------------------------------------------ montage data

## Everything used from a montage: its sequence clip, length, blends, warp windows (with the warp
## bone's transform in the root frame at each window's end), blend-out notify and MovingTraversal.
func _montage_info(asset: String) -> Dictionary:
	if _info_cache.has(asset):
		return _info_cache[asset]
	var mm: Dictionary = _montages[asset]
	var seg: Dictionary = mm["slots"][0]["segments"][0]
	var clip: String = ANIMS + seg["asset"] + ".fbx"
	var lib: AnimationLibrary = load(clip)
	var anim := lib.get_animation(lib.get_animation_list()[0])
	var info := {"asset": asset, "sequence": seg["asset"], "clip": clip, "anim": anim, "length": float(mm["length"]),
		"blend_in": float(mm["BlendIn"]["BlendTime"]), "blend_out_time": float(mm["BlendOut"]["BlendTime"]),
		"blend_out_trigger": float(mm.get("BlendOutTriggerTime", -1.0)), "auto_blend_out": bool(mm.get("bEnableAutoBlendOut", true)),
		"windows": [], "blend_out_notify": {}, "moving_traversal": 0.0}
	var tracks := _bone_tracks(anim, "root")
	info["root_pos"] = tracks[0]
	info["root_rot"] = tracks[1]
	for c: Dictionary in mm.get("curves", []):
		if c["name"] == "MovingTraversal" and (c["values"] as Array).size() > 0:
			info["moving_traversal"] = float(c["values"][0])
	# Clip math on the skeleton the clips were made for: Manny has no "attach" bone.
	var skeleton: Skeleton3D = Mannequin.clip_skeleton()
	for n: Dictionary in mm["notifies"]:
		match n["class"]:
			"AnimNotifyState_MotionWarping":
				var p: Dictionary = n["object"]["properties"]["RootMotionModifier"]
				var bone := ""
				if p.get("WarpPointAnimProvider", {}).get("name") == "Bone":
					bone = p.get("WarpPointAnimBoneName", "")
				var w := {"target": p["WarpTargetName"], "start": float(n["time"]), "end": float(n["end_time"]), "bone": bone,
					"rotation": bool(p.get("bWarpRotation", true)), "ignore_z": bool(p.get("bIgnoreZAxis", true)),
					"rotation_time_multiplier": float(p.get("WarpRotationTimeMultiplier", 1.0))}
				if bone != "":
					var b := skeleton.find_bone(bone)
					var bt := _bone_tracks(anim, bone)
					var local := _bone_local_at(anim, bt[0], bt[1], skeleton.get_bone_rest(b), w["end"])
					# attach is a child of root, so this is the bone in the root's frame.
					w["bone_rel"] = local if skeleton.get_bone_parent(b) == skeleton.find_bone("root") else Transform3D.IDENTITY
				info["windows"].append(w)
			"BP_NotifyState_MontageBlendOut":
				var props: Dictionary = n["object"].get("properties", {})
				var cond := String(props.get("BlendOutCondition", "NewEnumerator0")).trim_prefix("NewEnumerator").to_int()
				info["blend_out_notify"] = {"start": float(n["time"]), "end": float(n["end_time"]), "condition": cond,
					"time": float(props.get("BlendOutTime", 0.2)), "profile": props.get("BlendProfile", "")}
	info["windows"].sort_custom(func(a, b): return a["start"] < b["start"])
	_find_hand_contacts(info, anim, skeleton)
	_info_cache[asset] = info
	return info


## For each bone warp window, the first time in it the clip's hands reach the warp bone (the ledge):
## a wrist within 12 cm above it and no more than 10 cm short of it.
static func _find_hand_contacts(info: Dictionary, anim: Animation, skeleton: Skeleton3D) -> void:
	var sampler = CLIP_SAMPLER.new(anim, skeleton, false, [])
	var root_i := skeleton.find_bone("root")
	var hands := [skeleton.find_bone("hand_l"), skeleton.find_bone("hand_r")]
	for w: Dictionary in info["windows"]:
		if w["bone"] == "":
			continue
		var bone_i := skeleton.find_bone(w["bone"])
		var t: float = w["start"]
		while t <= w["end"] + 1e-6:
			var root_inv: Transform3D = sampler.bone(root_i, t).affine_inverse()
			var at: Vector3 = root_inv * sampler.bone(bone_i, t).origin
			var hit := false
			for h in hands:
				var hp: Vector3 = root_inv * sampler.bone(h, t).origin
				# Root frame: up is +Z, forward is -Y.
				if hp.z - at.z < 0.12 and (hp.y - at.y) < 0.10 and hp.z - at.z > -0.05:
					hit = true
			if hit:
				w["contact"] = t
				break
			t += 1.0 / 60.0


static func _bone_tracks(anim: Animation, bone: String) -> Array:
	var pos := -1
	var rot := -1
	for t in anim.get_track_count():
		if anim.track_get_path(t).get_concatenated_subnames() != bone:
			continue
		match anim.track_get_type(t):
			Animation.TYPE_POSITION_3D: pos = t
			Animation.TYPE_ROTATION_3D: rot = t
	return [pos, rot]


static func _map_clamped(v: float, in_a: float, in_b: float, out_a: float, out_b: float) -> float:
	return lerpf(out_a, out_b, clampf((v - in_a) / (in_b - in_a), 0.0, 1.0))
