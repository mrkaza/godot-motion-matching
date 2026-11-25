# The sample's motion matching anim graph on one character:
# trajectory -> per-frame variables -> CHT_PoseSearchDatabases (all results) -> continuing pose
# and full search over every chosen database -> blend stack ->
# offset root bone (rotation accumulates the animation's root motion) with steering toward the
# trajectory's facing 0.5 s ahead. The body's translation stays on the capsule (TranslationRadius 0).
class_name MotionMatcher
extends Node

const DATA := "res://extracted/data/"
const DB_DIR := "res://databases/"
const ROOT_CHOOSER := "CHT_PoseSearchDatabases"
## The Mover character's chooser: the CMC one has no slide. Its Slide table runs while sliding, and
## its slide exit rows (MovementMode_LastFrame == Sliding) on the first frame after.
const SLIDE_CHOOSER := "CHT_PoseSearchDatabases_Relaxed"
const CM := 0.01
const FINITE_DELTA := 1.0 / 60.0
const POSE_RESELECT_HISTORY := 0.3
const PLAY_RATE_MIN := 0.85
const PLAY_RATE_MAX := 1.15
const ROOT_BONE_RECOVERY_TIME := 0.3
const HEAVY_LAND_SPEED := 700.0
const STEER_PROCEDURAL_TIME := 0.4
const STEER_TARGET_TIME := 0.5        # Get_DesiredFacing samples the trajectory 0.5 s ahead
const STEER_BLEND := 0.1
const UP_AXIS := 2                    # root-local up (Unreal's Z), see bake_databases.gd
const FOOT_PLACEMENT := preload("res://scripts/motion/foot_placement.gd")
const BLEND_STACK_POSE := preload("res://scripts/motion/blend_stack_pose.gd")
const SLIDE_SLOPE := preload("res://scripts/motion/slide_slope.gd")
const SEQUENCES := "res://extracted/data/sequences.json"
# OrientationWarping_1 (AnimNode_OrientationWarping.h defaults).
const OW_ROTATION_INTERP_SPEED := 8.0
const OW_LOCOMOTION_ANGLE_DELTA_THRESHOLD := 135.0
const OW_MIN_ROOT_MOTION_SPEED := 10.0          # cm/s
const OW_COUNTER_COMPENSATE_INTERP_SPEED := 45.0
const OW_MAX_ROOT_MOTION_DELTA_TO_COMPENSATE := 45.0
const OW_MAX_CORRECTION := PI                   # MaxCorrectionDegrees 180
const RETARGET := preload("res://scripts/motion/retarget.gd")

@export var character_path: NodePath
@export var visual_path: NodePath

var character: GaspCharacter
var visual: Node3D
var skeleton: Skeleton3D
var trajectory := TransformTrajectory.new()
var chooser: ChooserEvaluator
var tree: AnimationTree
var blend: BlendStackNode

var databases := {}        # db path -> PoseDatabase
var searches := {}         # db path -> PoseSearch
var db_tags := {}          # db path -> Array
var clip_names := {}       # clip res path -> animation name in the tree

## Visual root yaw (radians), the offset root bone's simulated rotation.
var visual_yaw := 0.0
## The feet (scripts/motion/foot_placement.gd: the sample's Procedural_Feet), on the clip skeleton's pose
## before the retarget.
var foot_lock: SkeletonModifier3D
## The traversal component, if any: JustTraversed reads its MovingTraversal curve value.
var traversal: Node
var current_db := ""
var current_pose := -1
var current_cost := 0.0
var searched_dbs: Array = []
var vars := {}

var _last := {}
var _history: Array = []   # [db, pose, age]
## Per blend-stack player (by id): the state of its own Steering_1 / Steering_0 instances,
## [steer alpha, turn-in-place alpha, steer spring velocity, turn-in-place spring velocity].
var _steer_states := {}
## Per blend-stack player (by id): its OrientationWarping_1 instance,
## {actual, dir, rot, cc, first, updated}.
var _warp_states := {}
static var _warp_curves := {}   # sequence -> Enable_Warping curve
var _action_anims := {}         # tree animation names played as actions
var _movement_direction := "F"
## Blend profile and orientation warping on the pose (scripts/motion/blend_stack_pose.gd).
var blend_stack_pose: BLEND_STACK_POSE
## The Mover ABP's slide lean onto the slope (Procedural_PreLayering).
var slide_slope: SLIDE_SLOPE
var _prev_bone_rel := {}
var _speed_2d := 0.0
var _last_non_zero_velocity := Vector3.ZERO
## The retarget onto Manny (scripts/motion/retarget.gd); null with NO_RETARGET set.
var retarget: SkeletonModifier3D
## Tree animation name -> sequence name in sequences.json, for the retarget's curves.
var _sequence_of := {}


func _ready() -> void:
	if character == null:
		character = get_node(character_path)
	if visual == null:
		visual = get_node(visual_path)
	skeleton = Mannequin.find_skeleton(visual)
	chooser = ChooserEvaluator.new(JSON.parse_string(FileAccess.get_file_as_string(DATA + "choosers.json")))
	var db_json: Dictionary = JSON.parse_string(FileAccess.get_file_as_string(DATA + "databases.json"))
	for path: String in db_json:
		db_tags[path] = db_json[path].get("Tags", [])
	_load_databases(_reachable_databases(ROOT_CHOOSER))
	_load_databases(_reachable_databases(SLIDE_CHOOSER).filter(func(d: String): return d.contains("_Slide_")))
	_build_tree()
	# The feet run on the UEFN mannequin's pose, before the retarget (Mover ABP Procedural_Feet; BP_Manny
	# retargets the result).
	blend_stack_pose = BLEND_STACK_POSE.new()
	blend_stack_pose.name = "BlendStackPose"
	blend_stack_pose.tree = tree
	skeleton.add_child(blend_stack_pose)
	slide_slope = SLIDE_SLOPE.new()
	slide_slope.name = "SlideSlope"
	skeleton.add_child(slide_slope)
	foot_lock = FOOT_PLACEMENT.new()
	foot_lock.name = "FootPlacement"
	foot_lock.exclude.append(character.get_rid())
	skeleton.add_child(foot_lock)
	if not OS.has_environment("NO_RETARGET"):  # for A/B checks
		retarget = RETARGET.new()
		retarget.setup(skeleton)
	visual_yaw = character.yaw


## Every database a chooser can return (so their clips and searches are ready).
func _reachable_databases(root_chooser: String) -> Array:
	var found := {}
	var choosers: Dictionary = JSON.parse_string(FileAccess.get_file_as_string(DATA + "choosers.json"))
	var stack := [root_chooser]
	var seen := {}
	while stack:
		var name: String = stack.pop_back()
		if seen.has(name) or not choosers.has(name):
			continue
		seen[name] = true
		for t: Dictionary in choosers[name]["tables"].values():
			var results: Array = t["rows"].map(func(r): return r["result"])
			if t.get("fallback_result") != null:
				results.append(t["fallback_result"])
			for r: Dictionary in results:
				if r.get("type") == "Asset" and r.get("asset_class") == "PoseSearchDatabase":
					found[r["asset"]] = true
				elif r.get("type") == "EvaluateChooser":
					stack.append(r["chooser"])
	return found.keys()


func _load_databases(paths: Array) -> void:
	for path: String in paths:
		var file := DB_DIR + path + ".res"
		if not ResourceLoader.exists(file):
			push_warning("database not built: " + path)
			continue
		var db: PoseDatabase = load(file)
		databases[path] = db
		var s := PoseSearch.new()
		s.set_database(db.values, db.dims, db.weights, db.pose_addend, db.pose_blocked, db.pose_entry)
		searches[path] = s


func _build_tree() -> void:
	var player := visual.find_children("*", "AnimationPlayer", true, false)
	for p: AnimationPlayer in player:
		p.active = false
	tree = AnimationTree.new()
	visual.add_child(tree)
	tree.root_node = tree.get_path_to(skeleton.get_parent())
	tree.root_motion_track = NodePath("%s:root" % skeleton.get_parent().get_path_to(skeleton))
	tree.callback_mode_process = AnimationMixer.ANIMATION_CALLBACK_MODE_PROCESS_MANUAL
	tree.deterministic = true
	var index := 0
	for db: PoseDatabase in databases.values():
		for clip: String in db.entry_clip:
			if clip_names.has(clip):
				continue
			var lib: AnimationLibrary = load(clip).duplicate(true)
			Mannequin.strip_limb_positions(lib.get_animation(lib.get_animation_list()[0]))
			var lib_name := "c%d" % index
			index += 1
			tree.add_animation_library(lib_name, lib)
			clip_names[clip] = "%s/%s" % [lib_name, lib.get_animation_list()[0]]
			_sequence_of[clip_names[clip]] = clip.trim_prefix("res://extracted/anims/").trim_suffix(".fbx")
	blend = BlendStackNode.new()
	blend.blend_option = 1  # HermiteCubic
	blend.max_blend_in_time_to_override = 0.03
	blend.depth_blend_in_time_multiplier = 1.1
	var bt := AnimationNodeBlendTree.new()
	bt.add_node("blend_stack", blend)
	bt.connect_node("output", 0, "blend_stack")
	tree.tree_root = bt
	tree.active = true


# ------------------------------------------------------------------ per frame

func update(dt: float) -> void:
	trajectory.update(character, dt, _speed_2d, character.get_world_3d())
	_update_variables(dt)
	if action_clip == "":
		searched_dbs = _choose_databases()
		_motion_match(dt)
	tree.advance(dt)
	if retarget != null:
		retarget.update_curves(blend.get_players(), _sequence_of)
	foot_lock.update_contacts(blend.get_players(), _sequence_of)
	_update_action(dt)
	_update_visual_root(dt)
	for k in ["MovementMode", "MovementState", "Gait", "Stance"]:
		_last[k] = vars[k]


# ------------------------------------------------------------------ actions (the DefaultSlot)
# Traversal and get-up montages play here instead of the search, like Unreal's montage slot.
# While an action plays, motion matching doesn't search; when it ends (or stop_action is called)
# the next search starts from it, so the hand-back blends like any other pick.

signal action_finished(clip: String)

## res:// path of the clip playing as an action, "" when motion matching drives the body.
var action_clip := ""
## End time of the action in the clip (seconds); the action finishes there.
var action_end := 0.0
## World-space root motion of the action this frame (metres, radians), for callers that move the
## body by the animation (traversal, get-ups).
var action_root_translation := Vector3.ZERO
var action_root_turn := 0.0


## Plays part of a clip as an action. The clip must be loaded with load_clips() first.
func play_action(clip: String, start_time: float, end_time: float, blend_time: float, play_rate := 1.0) -> void:
	if not clip_names.has(clip):
		load_clips([clip])
	action_clip = clip
	action_end = end_time
	_action_anims[String(clip_names[clip])] = true
	blend.blend_to(clip_names[clip], start_time, false, blend_time, play_rate)
	current_db = ""
	current_pose = -1


## Ends the action now; motion matching picks the next pose on the next update.
func stop_action() -> void:
	if action_clip == "":
		return
	var clip := action_clip
	action_clip = ""
	action_finished.emit(clip)


## Adds clips to the animation tree (for actions that aren't in any searched database).
func load_clips(clips: Array) -> void:
	for clip: String in clips:
		if clip_names.has(clip):
			continue
		var lib: AnimationLibrary = load(clip).duplicate(true)
		Mannequin.strip_limb_positions(lib.get_animation(lib.get_animation_list()[0]))
		var lib_name := "a%d" % clip_names.size()
		tree.add_animation_library(lib_name, lib)
		clip_names[clip] = "%s/%s" % [lib_name, lib.get_animation_list()[0]]
		_sequence_of[clip_names[clip]] = clip.trim_prefix("res://extracted/anims/").trim_suffix(".fbx")


func _update_action(_dt: float) -> void:
	action_root_translation = Vector3.ZERO
	action_root_turn = 0.0
	if action_clip == "":
		return
	# Root motion of the blended pose, from the root's own frame to the world (visual root).
	var to_world := Basis(Vector3.UP, visual_yaw) * Mannequin.SKELETON_TURN
	action_root_translation = to_world * blend.get_root_delta_position()
	if blend.get_current_time() >= action_end - 1e-4:
		stop_action()


func _update_variables(dt: float) -> void:
	var p := character.properties()
	var velocity: Vector3 = p["velocity"]
	var accel: Vector3 = p["input_acceleration"]
	var prev_velocity: Vector3 = _last.get("velocity", velocity)
	_speed_2d = Vector2(velocity.x, velocity.z).length()
	if _speed_2d > 5.0:
		_last_non_zero_velocity = velocity
	var moving := velocity.length() > 0.1 and accel.length() > 1e-4
	var mode: String = {GaspCharacter.MovementMode.ON_GROUND: "OnGround", GaspCharacter.MovementMode.IN_AIR: "InAir",
		GaspCharacter.MovementMode.SLIDING: "Sliding"}[p["movement_mode"]]
	var state := "Moving" if moving else "Idle"
	var future_v := trajectory.velocity_between(0.4, 0.5)
	var tags: Array = db_tags.get(current_db, [])
	var turn := 0.0
	if accel.length() > 1e-4 and velocity.length() > 1e-4:
		turn = rad_to_deg(wrapf(atan2(accel.x, accel.z) - atan2(velocity.x, velocity.z), -PI, PI))
	var pivot_threshold := 45.0 if p["rotation_mode"] == 0 else 30.0
	var capsule_yaw: float = p["yaw"]
	var intent_yaw: float = capsule_yaw
	var last_state: String = _last.get("MovementState", state)
	var land_z := absf((p["land_velocity"] as Vector3).y)
	vars = {
		"MMDatabaseLOD": 0.0,
		"MovementMode": mode,
		"MovementState": state,
		"Gait": ["Walk", "Run", "Sprint"][p["gait"]],
		"Stance": "Stand" if p["stance"] == GaspCharacter.Stance.STAND else "Crouch",
		"Speed2D": _speed_2d,
		"IsStarting": moving and Vector2(future_v.x, future_v.z).length() >= _speed_2d + 100.0 and not tags.has("Pivots"),
		"IsPivoting": moving and absf(turn) >= pivot_threshold,
		"ShouldTurnInPlace": absf(rad_to_deg(wrapf(intent_yaw - visual_yaw, -PI, PI))) >= 50.0 and (p["wants_to_aim"] or (state == "Idle" and last_state == "Moving")),
		"ShouldSpinTransition": absf(rad_to_deg(wrapf(capsule_yaw - visual_yaw, -PI, PI))) >= 130.0 and _speed_2d >= 150.0 and not tags.has("Pivots"),
		# JustTraversed: no montage playing, MovingTraversal curve > 0, turn angle within 50 deg.
		"JustTraversed": action_clip == "" and traversal != null and float(traversal.moving_traversal) > 0.0 and absf(turn) <= 50.0,
		"JustLanded_Light": p["just_landed"] and land_z < HEAVY_LAND_SPEED,
		"JustLanded_Heavy": p["just_landed"] and land_z >= HEAVY_LAND_SPEED,
		"TrajectoryCollision.TimeToLand": trajectory.time_to_land,
	}
	_last["velocity"] = velocity


## The databases to search: the CMC chooser, the Mover chooser's Slide table while sliding, and its
## slide exit databases on the frame after a slide.
func _choose_databases() -> Array:
	var mode: String = vars["MovementMode"]
	var last: String = _last.get("MovementMode", mode)
	if mode == "Sliding":
		return chooser.evaluate_all(SLIDE_CHOOSER, _slide_context(last))
	var dbs := chooser.evaluate_all(ROOT_CHOOSER, vars)
	if last == "Sliding":
		for d: String in chooser.evaluate_all(SLIDE_CHOOSER, _slide_context(last)):
			if d.contains("_Slide_") and not dbs.has(d):
				dbs.append(d)
	return dbs


## The Mover chooser's inputs: these variables plus MovementMode_LastFrame and MovementDirection.
## The Mover pawn's MovementDirection (StrafeStyle 1) is F or B: B only when strafing with the
## velocity more than 140 deg off the facing (120 to go back to F), never when sprinting.
func _slide_context(last_mode: String) -> Dictionary:
	var c := vars.duplicate()
	c["MovementMode_LastFrame"] = last_mode
	var dir := "F"
	var v: Vector3 = character.velocity_cm
	if not character.orient_to_movement and Vector2(v.x, v.z).length() > 1e-4 and character.gait != GaspCharacter.Gait.SPRINT:
		var angle := absf(rad_to_deg(wrapf(atan2(v.x, v.z) - character.yaw, -PI, PI)))
		var lim := 120.0 if _movement_direction == "B" else 140.0
		dir = "F" if angle <= lim else "B"
	_movement_direction = dir
	c["MovementDirection"] = dir
	return c


func _interrupt() -> bool:
	if _last.is_empty():
		return false
	if vars["MovementMode"] != _last.get("MovementMode"):
		return true
	if vars["MovementMode"] == "OnGround":
		return vars["MovementState"] != _last.get("MovementState") \
			or (vars["Gait"] != _last.get("Gait") and vars["MovementState"] == "Moving") \
			or vars["Stance"] != _last.get("Stance")
	return false


func _motion_match(dt: float) -> void:
	# Age the reselect history (PoseIndicesHistory) and drop old entries.
	for h in _history:
		h[2] += dt
	_history = _history.filter(func(h): return h[2] <= POSE_RESELECT_HISTORY)

	var interrupt := _interrupt()
	var best_db := ""
	var best_pose := -1
	var best_cost := INF
	var queries := {}  # schema -> raw query

	# Continuing pose: the clip now playing, in the database it came from.
	var playing_clip := ""
	var playing_time := blend.get_current_time()
	var cont_entry := -1
	if current_db != "" and current_pose >= 0 and databases.has(current_db):
		var db: PoseDatabase = databases[current_db]
		cont_entry = db.pose_entry[current_pose]
		playing_clip = db.entry_clip[cont_entry]
		var skip := interrupt and not searched_dbs.has(current_db)
		var pose := db.pose_index(cont_entry, playing_time)
		if not skip and pose >= 0:
			var raw := _query(db, queries, db, pose)
			var q: PackedFloat32Array = searches[current_db].weigh(raw)
			var bias := db.pose_continuing_bias[pose]
			if is_nan(bias):
				bias = db.continuing_pose_cost_bias
			best_cost = searches[current_db].feature_cost(pose, q) + db.pose_addend[pose] + bias
			best_db = current_db
			best_pose = pose

	var cont_db: PoseDatabase = databases[best_db] if best_pose >= 0 else null
	var cont_pose := best_pose
	for path: String in searched_dbs:
		if not databases.has(path):
			continue
		var db: PoseDatabase = databases[path]
		var raw := _query(db, queries, cont_db, cont_pose)
		var q: PackedFloat32Array = searches[path].weigh(raw)
		var excluded := PackedInt32Array()
		for h in _history:
			if h[0] == path:
				excluded.append(h[1])
		var excluded_entries := PackedInt32Array()
		if path == current_db and cont_entry >= 0 and db.entry_disable_reselection[cont_entry]:
			excluded_entries.append(cont_entry)
		var r: PackedFloat32Array = searches[path].search(q, excluded, excluded_entries, best_cost)
		if r[0] >= 0:
			best_cost = r[1]
			best_db = path
			best_pose = int(r[0])

	if best_pose < 0:
		return
	var db: PoseDatabase = databases[best_db]
	var continuing := best_db == current_db and best_pose >= 0 and current_pose >= 0 \
		and db.pose_entry[best_pose] == db.pose_entry[current_pose] and db.pose_index(db.pose_entry[best_pose], playing_time) == best_pose
	var rate := _play_rate(db, best_pose, queries)
	if continuing:
		blend.set_play_rate(rate)
		current_pose = best_pose
	else:
		var entry := db.pose_entry[best_pose]
		blend.blend_to(clip_names[db.entry_clip[entry]], db.pose_time[best_pose], db.entry_loops[entry] == 1, _blend_time(), rate)
		current_db = best_db
		current_pose = best_pose
	current_cost = best_cost
	_history.append([best_db, best_pose, 0.0])


# Get_MMBlendTime.
func _blend_time() -> float:
	var mode: String = vars["MovementMode"]
	var last: String = _last.get("MovementMode", mode)
	# The Mover ABP's Get_MMBlendTime: 0.2 while sliding and on the frame after.
	if mode == "Sliding" or (mode == "OnGround" and last == "Sliding"):
		return 0.2
	if mode == "OnGround":
		return 0.5 if last == "OnGround" else (0.2 if last == "InAir" else 0.0)
	if mode == "InAir":
		return 0.15 if character.velocity_cm.y > 100.0 else 0.5
	return 0.0


# WantedPlayRate: clamp(sum |query velocity| / sum |pose velocity|) over trajectory velocities.
func _play_rate(db: PoseDatabase, pose: int, queries: Dictionary) -> float:
	var raw: PackedFloat32Array = queries.get(db.schema_name, PackedFloat32Array())
	if raw.is_empty():
		return 1.0
	var q_sum := 0.0
	var p_sum := 0.0
	for leaf: Dictionary in db.leaves:
		if leaf["type"] != "Velocity" or leaf.get("bNormalize", false) or not leaf.has("expanded_from"):
			continue
		var off := int(leaf["offset"])
		var qv := 0.0
		var pv := 0.0
		for i in int(leaf["cardinality"]):
			qv += raw[off + i] * raw[off + i]
			var v := db.raw_value(pose, off + i)
			pv += v * v
		q_sum += sqrt(qv)
		p_sum += sqrt(pv)
	if p_sum <= 1e-4:
		return 1.0
	return clampf(q_sum / p_sum, PLAY_RATE_MIN, PLAY_RATE_MAX)


# ------------------------------------------------------------------ query (posesearch_spec section 2)

## Raw query for a database's schema (cached per schema). Channels that use the continuing pose
## copy its stored values when the continuing pose is in a database with the same schema.
func _query(db: PoseDatabase, cache: Dictionary, cont_db: PoseDatabase, cont_pose: int) -> PackedFloat32Array:
	var key := db.schema_name + ("|c" if cont_db != null and cont_db.schema_name == db.schema_name and cont_pose >= 0 else "")
	if cache.has(key):
		return cache[key]
	var row := PackedFloat32Array()
	row.resize(db.dims)
	var use_cont := cont_db != null and cont_pose >= 0 and cont_db.schema_name == db.schema_name
	for leaf: Dictionary in db.leaves:
		var off := int(leaf["offset"])
		var card := int(leaf["cardinality"])
		var input: String = leaf.get("InputQueryPose", {"name": "UseCharacterPose"})["name"]
		if input != "UseCharacterPose" and use_cont:
			for i in card:
				row[off + i] = cont_db.raw_value(cont_pose, off + i)
			continue
		var ts := float(leaf.get("SampleTimeOffset", 0.0))
		var to := float(leaf.get("OriginTimeOffset", 0.0))
		var bone = leaf.get("bone")
		var strip: String = leaf.get("ComponentStripping", {"name": "None"})["name"]
		var trajectory_leaf: bool = bone == null or bone == "root"
		var v := Vector3.ZERO
		var normalize := false
		match leaf["type"]:
			"Position":
				v = _traj_displacement(ts, to) if trajectory_leaf else _bone_displacement(bone, leaf.get("origin_bone"))
				if leaf.get("bNormalizeDisplacement", false):
					v = v.limit_length(1.0)
			"Velocity":
				if trajectory_leaf:
					var to_prev := to - FINITE_DELTA if leaf.get("bUseCharacterSpaceVelocities", true) else to
					v = (_traj_displacement(ts, to) - _traj_displacement(ts - FINITE_DELTA, to_prev)) / FINITE_DELTA
				else:
					v = _bone_velocity(bone, leaf.get("origin_bone"))
				if leaf.get("bNormalize", false):
					v = v.limit_length(1.0)
			"Heading":
				var axis: String = leaf.get("HeadingAxis", {"name": "X"})["name"]
				var rel := _root_basis(to).inverse() * (_root_basis(ts) if trajectory_leaf else _bone_basis(bone))
				v = rel.x if axis == "X" else (rel.y if axis == "Y" else rel.z)
				normalize = true
			"Curve", "Distance":
				row[off] = 0.0
				continue
			_:
				continue
		_encode(row, off, v, strip, normalize)
	cache[key] = row
	return row


## Root transform at a trajectory time: trajectory position and facing, with the visual root's
## offset recovering to the capsule over ROOT_BONE_RECOVERY_TIME (pose history root recovery).
func _root_basis(t: float) -> Basis:
	var s := trajectory.sample_at(t)
	var offset := wrapf(visual_yaw - float(trajectory.sample_at(0.0)[1]), -PI, PI)
	var recover := 1.0 - clampf(t / ROOT_BONE_RECOVERY_TIME, 0.0, 1.0) if t > 0.0 else 1.0
	return Basis(Vector3.UP, float(s[1]) + offset * recover) * Mannequin.SKELETON_TURN


func _traj_displacement(ts: float, to: float) -> Vector3:
	var p_s: Vector3 = trajectory.sample_at(ts)[0]
	var p_o: Vector3 = trajectory.sample_at(to)[0]
	return _root_basis(to).inverse() * (p_s - p_o) / CM


## A bone as the databases measured it: on the clips' own skeleton (see retarget.gd),
## so the query isn't skewed by Manny's longer limbs.
func _bone_world(bone: String) -> Transform3D:
	return skeleton.global_transform * RETARGET.source_pose(skeleton, bone)


func _bone_displacement(bone: String, origin) -> Vector3:
	var root_pos: Vector3 = trajectory.sample_at(0.0)[0]
	var b := _bone_world(bone).origin
	var o := root_pos if origin == null or origin == "root" else _bone_world(origin).origin
	return _root_basis(0.0).inverse() * (b - o) / CM


func _bone_velocity(bone: String, origin) -> Vector3:
	var key := "%s|%s" % [bone, origin]
	var now := _bone_displacement(bone, origin)
	var prev: Vector3 = _prev_bone_rel.get(key, now)
	return (now - prev) / maxf(get_physics_process_delta_time(), 1e-4)


func _bone_basis(bone: String) -> Basis:
	return _bone_world(bone).basis.orthonormalized()


static func _encode(row: PackedFloat32Array, offset: int, v: Vector3, strip: String, normalize: bool) -> void:
	match strip:
		"StripZ":
			var h := Vector2(v.x, v.y)
			if normalize and h.length_squared() > 1e-8:
				h = h.normalized()
			row[offset] = h.x
			row[offset + 1] = h.y
		"StripXY":
			var z := v.z
			if normalize and z * z > 1e-8:
				z = signf(z)
			row[offset] = z
		_:
			if normalize and v.length_squared() > 1e-8:
				v = v.normalized()
			row[offset] = v.x
			row[offset + 1] = v.y
			row[offset + 2] = v.z


# ------------------------------------------------------------------ visual root

## Offset root bone (rotation Accumulate): the visual turns only by the animation's root rotation.
## Like the blend stack's per-sample graph, every player in the
## stack runs its own two Steering nodes on its own root motion and clip before the players'
## root motions blend by weight (AnimNode_Steering.cpp). Steering_1 is on for the newest player
## only (EnableSteering: GetCurrentBlendStackAnimIsActive), so older players fade theirs out.
func _update_visual_root(dt: float) -> void:
	var q := blend.get_root_delta_rotation()
	var anim_turn := 2.0 * atan2(q.z, q.w)  # twist about the root's up (Unreal Z)
	blend_stack_pose.root_angle = 0.0
	blend_stack_pose.spine_angle = 0.0
	blend_stack_pose.foot_angle = 0.0
	blend_stack_pose.players = _clocks(blend.get_players()) if action_clip == "" else []
	if action_clip == "" and dt > 0.0:
		anim_turn = _steered_turn(dt)
	elif action_clip != "":
		_warp_states.clear()  # the montage covers the blend stack; warping resets when it comes back
	visual_yaw = wrapf(visual_yaw + anim_turn, -PI, PI)
	# E_MovementMode for the feet: Traversing while a traversal montage plays, else the movement mode.
	var traversing: bool = traversal != null and traversal.get("doing_traversal") == true
	foot_lock.movement_mode = "Traversing" if traversing else vars.get("MovementMode", "OnGround")
	foot_lock.ground_normal = character.get_floor_normal() if character.is_on_floor() else Vector3.UP
	_update_slide_slope(dt)
	visual.global_position = character.global_position
	visual.global_basis = Basis(Vector3.UP, visual_yaw)
	# Remember this frame's bone positions for next frame's velocities.
	for b in ["foot_l", "foot_r", "pelvis"]:
		for o in [null, "root", "foot_r"]:
			_prev_bone_rel["%s|%s" % [b, o]] = _bone_displacement(b, o)


## Update_FloorValues (the pawn's floor hit: its impact point and normal, else the mesh and up) and
## the slide lean's smoothing and blend.
func _update_slide_slope(dt: float) -> void:
	slide_slope.sliding = character.movement_mode == GaspCharacter.MovementMode.SLIDING
	slide_slope.ground_point = visual.global_position
	slide_slope.ground_normal = Vector3.UP
	if character.is_on_floor():
		var from := character.global_position + Vector3.UP * 0.5
		var q := PhysicsRayQueryParameters3D.create(from, from + Vector3.DOWN * 1.0)
		q.exclude = [character.get_rid()]
		var space := character.get_world_3d().direct_space_state
		var hit := space.intersect_ray(q)
		while hit and not (hit["collider"] is StaticBody3D):  # the character's own bodies
			q.exclude = q.exclude + [hit["rid"]]
			hit = space.intersect_ray(q)
		if hit:
			slide_slope.ground_point = hit["position"]
			slide_slope.ground_normal = hit["normal"]
	slide_slope.update(dt)


## This frame's root yaw of the blend stack after each player's Steering nodes, blended by weight.
func _steered_turn(dt: float) -> float:
	var target := float(trajectory.sample_at(STEER_TARGET_TIME)[1])
	var steer_on: bool = vars.get("MovementState") == "Moving" or vars.get("MovementMode") == "InAir"
	var tip_on: bool = db_tags.get(current_db, []).has("TurnInPlace")
	var players := blend.get_players()
	# Blend profile FastFeet+Root_Weight: root motion blends with the root's weights (BlendTime / 10).
	var clocks := _clocks(players)
	var root_w := BLEND_STACK_POSE.weights(clocks, BLEND_STACK_POSE.ROOT_SCALE)
	var foot_w := BLEND_STACK_POSE.weights(clocks, 1.5)
	var states := {}
	var sum := Quaternion(0, 0, 0, 0)
	var warp_states := {}
	for i in players.size():
		var p: Array = players[i]
		var on := steer_on and i == 0
		# A new player's graph starts with each alpha at its target (FInputAlphaBoolBlend).
		var st: Array = _steer_states.get(p[3], [1.0 if on else 0.0, 1.0 if tip_on else 0.0, 0.0, 0.0])
		st[0] = move_toward(st[0], 1.0 if on else 0.0, dt / STEER_BLEND)
		st[1] = move_toward(st[1], 1.0 if tip_on else 0.0, dt / STEER_BLEND)
		states[p[3]] = st
		var dq: Quaternion = p[5]
		var turn := 2.0 * atan2(dq.z, dq.w)
		var speed_cm := (p[4] as Vector3).length() / CM / dt
		# OrientationWarping_1 comes first in the graph; its angle blends with each bone's weights.
		var warp := _orientation_warp(p, dt)
		blend_stack_pose.root_angle += warp * root_w[i]
		blend_stack_pose.spine_angle += warp * float(p[2])
		blend_stack_pose.foot_angle += warp * foot_w[i]
		# Steering_1: disabled below 10 cm/s of root motion; procedural 0.4 s, animated 2.0 s.
		if st[0] > 0.0 and speed_cm > 10.0:
			turn = _steer(turn, target, st, 0, p[0], p[1], STEER_PROCEDURAL_TIME, 2.0, dt)
		# Steering_0 (turn in place): never disabled by speed; procedural 1e6 s, animated 2.0 s.
		if st[1] > 0.0:
			turn = _steer(turn, target, st, 1, p[0], p[1], 1000000.0, 2.0, dt)
		var r := Quaternion(Vector3(0, 0, 1), turn)
		if sum.dot(r) < 0.0:
			r = -r
		sum += r * root_w[i]
	_steer_states = states
	for p: Array in players:
		warp_states[p[3]] = _warp_states[p[3]]
	_warp_states = warp_states
	if sum.length_squared() <= 0.0:
		return 0.0
	sum = sum.normalized()
	return 2.0 * atan2(sum.z, sum.w)


## [name, time, blend-in time, blend time, profiled] per player for blend_stack_pose.gd: a player
## that is an action clip, or blends in over one, doesn't use the MM node's blend profile.
func _clocks(players: Array) -> Array:
	var out := []
	for i in players.size():
		var p: Array = players[i]
		var older_is_action := i + 1 < players.size() and _action_anims.has(String(players[i + 1][0]))
		out.append([p[0], p[1], p[6], p[7], not (_action_anims.has(String(p[0])) or older_is_action)])
	return out


## One player's OrientationWarping_1 (Graph mode, WarpingSpace RootBoneTransform, TargetTime 0,
## LocomotionDirection = LastNonZeroVelocity, alpha = the clip's Enable_Warping curve). Returns the
## angle it turns that player's pose by (radians about the root's up), alpha applied.
func _orientation_warp(p: Array, dt: float) -> float:
	var st: Dictionary = _warp_states.get(p[3], {"actual": 0.0, "dir": Vector3.ZERO, "rot": Quaternion(), "cc": 0.0, "first": true, "updated": false})
	_warp_states[p[3]] = st
	var alpha := clampf(_warp_alpha(p[0], p[1]), 0.0, 1.0)
	if alpha <= 0.00001:  # not relevant: the node doesn't update
		st["updated"] = false
		return 0.0
	if not st["first"] and not st["updated"]:  # became relevant again: Reset
		st["first"] = true
		st["dir"] = Vector3.ZERO
		st["actual"] = 0.0
	st["updated"] = true
	# Root-local frame (Unreal's root bone space): up is +Z.
	var to_local := (Basis(Vector3.UP, visual_yaw) * Mannequin.SKELETON_TURN).inverse()
	var loco := to_local * _last_non_zero_velocity
	loco = Vector3(loco.x, loco.y, 0.0).normalized()
	var rm: Vector3 = p[4]
	rm = Vector3(rm.x, rm.y, 0.0)
	var prev_rot: Quaternion = st["rot"]
	st["rot"] = p[5]
	var target := 0.0
	if rm.length() / CM / dt >= OW_MIN_ROOT_MOTION_SPEED and loco != Vector3.ZERO:
		var prev_dir: Vector3 = st["dir"]
		var dir: Vector3 = rm.normalized() if rm.length_squared() > 1e-8 else prev_dir
		target = _signed_angle(dir, loco)
		if absf(rad_to_deg(target)) > OW_LOCOMOTION_ANGLE_DELTA_THRESHOLD:
			target = wrapf(target + PI, -PI, PI)
			dir = -dir
		st["dir"] = dir
		if prev_dir.length_squared() > 1e-8:
			var delta := _signed_angle(dir, prev_rot.inverse() * prev_dir)
			if absf(delta) < deg_to_rad(OW_MAX_ROOT_MOTION_DELTA_TO_COMPENSATE):
				st["cc"] += delta
				var cca := _finterp_to(0.0, st["cc"], dt, OW_COUNTER_COMPENSATE_INTERP_SPEED)
				st["actual"] = wrapf(st["actual"] + cca, -PI, PI)
				st["cc"] -= cca
	var actual: float = st["actual"]
	if not st["first"]:
		actual = clampf(_finterp_to(actual, target, dt, OW_ROTATION_INTERP_SPEED), actual - OW_MAX_CORRECTION, actual + OW_MAX_CORRECTION)
	else:
		actual = target
	actual = clampf(actual, -OW_MAX_CORRECTION, OW_MAX_CORRECTION) * alpha
	st["actual"] = actual
	st["first"] = false
	return actual


func _warp_alpha(clip: StringName, time: float) -> float:
	if _warp_curves.is_empty():
		var seqs: Dictionary = JSON.parse_string(FileAccess.get_file_as_string(SEQUENCES))
		for seq: String in seqs:
			for c: Dictionary in seqs[seq].get("curves", []):
				if String(c["name"]).to_lower() == "enable_warping":
					_warp_curves[seq] = c
	var c = _warp_curves.get(_sequence_of.get(clip, ""))
	return RETARGET.eval_curve(c, time) if c != null else 0.0


## UE::Anim::SignedAngleRadBetweenNormals about the root's up (+Z).
static func _signed_angle(from: Vector3, to: Vector3) -> float:
	var a := acos(clampf(from.dot(to), -1.0, 1.0))
	return a if from.cross(to).z >= 0.0 else -a


## FMath::FInterpTo.
static func _finterp_to(current: float, target: float, dt: float, speed: float) -> float:
	if speed <= 0.0:
		return target
	var dist := target - current
	if dist * dist < 1e-8:
		return target
	return current + dist * clampf(dt * speed, 0.0, 1.0)


## One Steering node on a player's root yaw this frame (radians). Scales the clip's own turn so its
## predicted turn over `animated_time` lands on the target (ratio clamped 0.5..1.5), then closes
## the rest with a critically damped spring (SpringMath::CriticalSpringDamperQuat, half-life
## `procedural_time`). `slot` picks the node: its alpha is st[slot], its spring velocity st[slot + 2].
func _steer(turn: float, target: float, st: Array, slot: int, clip: StringName, time: float, procedural_time: float, animated_time: float, dt: float) -> float:
	var alpha: float = st[slot]
	var to_target := wrapf(target - visual_yaw, -PI, PI)
	var predicted := _predicted_root_yaw(clip, time, animated_time)
	if absf(rad_to_deg(predicted)) > 1.0:  # RootMotionThreshold, degrees
		var yaw_to_target := to_target
		if predicted - yaw_to_target > PI:
			yaw_to_target += TAU
		elif yaw_to_target - predicted > PI:
			yaw_to_target -= TAU
		var ratio := lerpf(1.0, clampf(yaw_to_target / predicted, 0.5, 1.5), alpha)
		turn *= ratio
		to_target = wrapf(target - (visual_yaw + predicted * ratio), -PI, PI)
	# Critical spring from no correction toward the remaining angle, for this frame only.
	var smoothing := procedural_time / log(2.0)
	var y := 4.0 / maxf(smoothing, 1e-8) / 2.0
	var v: float = st[slot + 2]
	var j0 := -to_target
	var j1 := v + j0 * y
	var x := y * dt
	var eydt := 1.0 / (1.0 + 1.00746054 * x + 0.45053901 * x * x + 0.25724632 * x * x * x)
	var correction := eydt * (j0 + j1 * dt) + to_target
	st[slot + 2] = eydt * (v - j1 * y * dt)
	return turn + correction * alpha


## Root yaw a clip turns by over the next `seconds` from `t0` (looping clips wrap).
func _predicted_root_yaw(clip: StringName, t0: float, seconds: float) -> float:
	var anim: Animation = tree.get_animation(clip)
	if anim == null:
		return 0.0
	var track := anim.find_track(NodePath("Skeleton3D:root"), Animation.TYPE_ROTATION_3D)
	if track < 0:
		return 0.0
	var length := anim.length
	var looping := anim.loop_mode != Animation.LOOP_NONE
	var total := 0.0
	var remaining := seconds
	var t := t0
	while remaining > 1e-4:
		var step := minf(remaining, length - t)
		if step <= 0.0:
			if not looping:
				break
			t = 0.0
			continue
		var qa := anim.rotation_track_interpolate(track, t)
		var qb := anim.rotation_track_interpolate(track, t + step)
		var d := qa.inverse() * qb
		total += 2.0 * atan2(d.z, d.w)
		remaining -= step
		t += step
		if t >= length - 1e-5 and looping:
			t = 0.0
		elif t >= length - 1e-5:
			break
	return total
