# The sample's paired character interactions (shove, tackle, takedown) as SandboxCharacter_Mover_Ragdoll
# does them. Add one to every character that
# takes part (the player and the NPCs); the one whose key is pressed is the attacker.
#   CheckForInteractableCharacters: other characters within 200 cm, on the ground, at the same height
#     (+-50 cm), within +-60 deg of the capsule's facing, nothing in between.
#   TryCharacterInteraction(type): CHT_CharacterInteractionPSDs in AllResults mode on {type, speed}
#     (Shove: below 200 cm/s the shoves, from 200 the tackles; Takedown: stand <= 150, walk 150-200,
#     run >= 200) -> MotionMatchMulti over every chosen database and every candidate: the query is the
#     two roots relative to each other (schema PSS_CharacterInteraction), the best pose gives the
#     PoseSearchInteractionAsset and the asset time both montages start from.
#   Alignment (UPoseSearchInteractionAsset::CalculateWarpTransforms, MinimalTranslationWeight 1):
#     the victim keeps its place and turns so the attacker is where the asset has it; the attacker is
#     put at the asset's distance along the current line to the victim, turned the same way. The
#     targets are taken at the end of each montage's BP_NotifyState_MMI_MotionWarping window and
#     reached by skew-warping the root motion inside it (SkewWarp: translation and rotation).
#   Both montages play in the matchers' action slots in sync; capsules ignore each other; at the
#     BP_AnimNotify_TriggerRagdoll notify the character ragdolls with the notify's injury state (the
#     victim, and the attacker too in tackles); the ragdoll component's get-ups follow. Movement input
#     in BP_NotifyState_MontageBlendOut windows ends the attacker's montage early.
# Keys (player only): F = Shove (a tackle when running), Q = Takedown.
extends Node

const DATA := "res://extracted/data/"
const ANIMS := "res://extracted/anims/"
const DB_DIR := "res://databases/"
const CM := 0.01
const CHOOSER := "CHT_CharacterInteractionPSDs"
const GROUP := "interaction_characters"
const RADIUS := 2.0                  # SphereOverlapActors r = 200 cm
const HEIGHT_TOLERANCE := 0.5        # NearlyEqual(Z, 50)
const MAX_YAW := 60.0                # InRange(yaw, -60, 60)
const WORLD_MASK := 1

enum Role { NONE, ATTACKER, VICTIM }

signal interaction_started(result: Dictionary)
signal interaction_finished(role: int)

static var _data := {}               # shared: chooser rows, databases, interaction assets, montages

var player: Player
var character: GaspCharacter
var matcher: MotionMatcher
var ragdoll: Node
var role := Role.NONE
var partner: Node                    # the other character's interaction component
var montage := {}                    # this character's montage info
var montage_time := 0.0
## The last interaction this character started or took part in: {type, db, asset, time, cost,
## attacker, victim, targets (role -> Transform3D at the first window's end)}.
var last := {}
var _targets := []                   # per warp window: {"pos", "yaw"}
var _ragdolled := false
var _ignoring: GaspCharacter          # the partner's capsule this capsule ignores


func _ready() -> void:
	player = get_parent()
	character = player.character
	matcher = player.matcher
	add_to_group(GROUP)
	for c in player.components:
		if c != self and c.has_method("trigger_ragdoll"):
			ragdoll = c
	if _data.is_empty():
		_load_data()


static func _load_data() -> void:
	var choosers: Dictionary = JSON.parse_string(FileAccess.get_file_as_string(DATA + "choosers.json"))
	var table: Dictionary = choosers[CHOOSER]["tables"][choosers[CHOOSER]["root_table"]]
	var rows := []
	for r: Dictionary in table["rows"]:
		if r.get("disabled", false):
			continue
		var row := {"db": r["result"]["asset"]}
		for col: Dictionary in table["columns"]:
			var v = col.get("row_values", [])[int(r["index"])]
			match col["type"]:
				"ChooserNameColumn":
					row["type"] = v["value"]
				"FloatRangeColumn":
					row["min"] = -INF if v.get("bNoMin", false) else float(v["Min"])
					row["max"] = INF if v.get("bNoMax", false) else float(v["Max"])
		rows.append(row)
	_data["rows"] = rows
	_data["databases"] = {}
	for r: Dictionary in rows:
		var path: String = DB_DIR + String(r["db"]) + ".res"
		if ResourceLoader.exists(path):
			_data["databases"][r["db"]] = load(path)
	_data["interactions"] = JSON.parse_string(FileAccess.get_file_as_string(DATA + "interactions.json"))
	_data["montages"] = JSON.parse_string(FileAccess.get_file_as_string(DATA + "montages.json"))
	_data["infos"] = {}


# ------------------------------------------------------------------ input

func on_key(event: InputEvent) -> bool:
	if player.is_npc:
		return false
	var key := event as InputEventKey
	if key != null and key.physical_keycode == KEY_F:
		try_interaction("Shove")
		return true
	if key != null and key.physical_keycode == KEY_Q:
		try_interaction("Takedown")
		return true
	return false


# ------------------------------------------------------------------ candidates

func is_busy() -> bool:
	return role != Role.NONE or (ragdoll != null and ragdoll.has_method("is_ragdoll") and ragdoll.is_ragdoll()) \
		or matcher.action_clip != "" or not player.matcher_enabled


## CanDoCharacterInteraction: on the ground, no montage playing.
func can_interact() -> bool:
	return character.movement_mode == GaspCharacter.MovementMode.ON_GROUND and not is_busy()


## CanBeInteractedWith: on the ground (and not already in an interaction or ragdolled).
func can_be_interacted_with() -> bool:
	return character.movement_mode == GaspCharacter.MovementMode.ON_GROUND and role == Role.NONE \
		and not (ragdoll != null and ragdoll.has_method("is_ragdoll") and ragdoll.is_ragdoll())


func find_candidates() -> Array:
	var out := []
	var me := character.global_position
	var fwd := character.forward()
	for c in get_tree().get_nodes_in_group(GROUP):
		if c == self or not c.can_be_interacted_with():
			continue
		var other: Vector3 = c.character.global_position
		var d := other - me
		if Vector2(d.x, d.z).length() > RADIUS or absf(d.y) > HEIGHT_TOLERANCE:
			continue
		var yaw := rad_to_deg(wrapf(atan2(d.x, d.z) - atan2(fwd.x, fwd.z), -PI, PI))
		if absf(yaw) > MAX_YAW:
			continue
		# CapsuleTraceSingleByProfile(self -> other, r 20, half height 60), ignoring both.
		var params := PhysicsShapeQueryParameters3D.new()
		var cap := CapsuleShape3D.new()
		cap.radius = 0.2
		cap.height = 1.2
		params.shape = cap
		params.transform = Transform3D(Basis.IDENTITY, me + Vector3.UP * 0.88)
		params.motion = d
		params.collision_mask = WORLD_MASK
		params.exclude = [character.get_rid(), c.character.get_rid()]
		var r := character.get_world_3d().direct_space_state.cast_motion(params)
		if r.size() == 2 and r[1] < 1.0:
			continue
		out.append(c)
	return out


# ------------------------------------------------------------------ search

## Root of a character as the pose search sees it: the mesh root (capsule floor point, mesh yaw).
func root_transform() -> Transform3D:
	return Transform3D(Basis(Vector3.UP, matcher.visual_yaw) * Mannequin.SKELETON_TURN, character.global_position)


static func _query(db: PoseDatabase, attacker: Transform3D, victim: Transform3D) -> PackedFloat32Array:
	var q := PackedFloat32Array()
	q.resize(db.dims)
	for leaf: Dictionary in db.leaves:
		var sample := attacker if leaf["SampleRole"] == "Attacker" else victim
		var origin := attacker if leaf["OriginRole"] == "Attacker" else victim
		var v := origin.affine_inverse() * sample.origin / CM
		var off := int(leaf["offset"])
		q[off] = v.x
		q[off + 1] = v.y
		q[off + 2] = v.z
	return q


## TryCharacterInteraction: returns the picked result ({} when nothing was started).
func try_interaction(type: String) -> Dictionary:
	if not can_interact():
		return {}
	var candidates := find_candidates()
	if candidates.is_empty():
		return {}
	var speed := character.speed_2d()
	var best := {}
	var best_cost := INF
	for row: Dictionary in _data["rows"]:
		if row["type"] != type or speed < row["min"] or speed > row["max"]:
			continue
		var db: PoseDatabase = _data["databases"].get(row["db"])
		if db == null:
			continue
		for c in candidates:
			var q := _query(db, root_transform(), c.root_transform())
			for p in db.pose_count():
				if db.pose_blocked[p]:
					continue
				var cost: float = db.pose_addend[p]
				for d in db.dims:
					var e := db.values[p * db.dims + d] - q[d] * db.weights[d]
					cost += e * e
				if cost < best_cost:
					best_cost = cost
					best = {"type": type, "db": row["db"], "asset": db.entry_clip[db.pose_entry[p]].trim_prefix("psia:"),
						"time": db.pose_time[p], "cost": cost, "victim": c, "speed": speed}
	if best.is_empty():
		return {}
	_start(best)
	return best


# ------------------------------------------------------------------ start

func _start(r: Dictionary) -> void:
	var victim: Node = r["victim"]
	var psia: Dictionary = _data["interactions"][String(r["asset"]).get_file()]
	var items := {}
	for item: Dictionary in psia["Items"]:
		items[item["Role"]] = item
	var a_info := _montage_info(items["Attacker"]["asset"])
	var v_info := _montage_info(items["Victim"]["asset"])
	var t: float = r["time"]
	var actors := {"Attacker": root_transform(), "Victim": victim.root_transform()}
	var infos := {"Attacker": a_info, "Victim": v_info}
	# Asset roots (world axes, the asset's own placement) at the selected time.
	var asset := {}
	for role_name: String in items:
		asset[role_name] = _asset_root(items[role_name], infos[role_name], t)
	var aligned := {
		"Attacker": _full_aligned(actors["Attacker"], asset["Attacker"], actors["Victim"].origin, asset["Victim"].origin, false),
		"Victim": _full_aligned(actors["Victim"], asset["Victim"], actors["Attacker"].origin, asset["Attacker"].origin, true),
	}
	r["aligned"] = aligned
	r["items"] = items
	r["infos"] = infos
	r["attacker"] = self
	last = r
	victim.last = r
	_begin(Role.ATTACKER, victim, a_info, items["Attacker"], aligned["Attacker"], asset["Attacker"], t)
	victim._begin(Role.VICTIM, self, v_info, items["Victim"], aligned["Victim"], asset["Victim"], t)
	interaction_started.emit(r)


## Where the victim should be relative to the attacker at asset time t (the asset's placement):
## [position in the attacker's root frame (m), yaw of the victim relative to the attacker].
func expected_relative(r: Dictionary, t: float) -> Array:
	var a := _asset_root(r["items"]["Attacker"], r["infos"]["Attacker"], t)
	var v := _asset_root(r["items"]["Victim"], r["infos"]["Victim"], t)
	return _relative(a, v)


static func _relative(a: Transform3D, v: Transform3D) -> Array:
	var rel := a.affine_inverse() * v
	var fa := a.basis * Mannequin.SKELETON_TURN.inverse() * Vector3(0, 0, 1)
	var fv := v.basis * Mannequin.SKELETON_TURN.inverse() * Vector3(0, 0, 1)
	return [rel.origin, wrapf(atan2(fv.x, fv.z) - atan2(fa.x, fa.z), -PI, PI)]


## The same, measured on the two characters now.
static func actual_relative(attacker: Node, victim: Node) -> Array:
	return _relative(attacker.root_transform(), victim.root_transform())


## Root of a role in the asset at asset time t: Origin * root motion from the montage's start.
func _asset_root(item: Dictionary, info: Dictionary, t: float) -> Transform3D:
	var o: Dictionary = item["Origin"]
	var q: Array = o["rotation_xyzw"]
	var tr: Array = o["translation"]
	var origin := Transform3D(Basis(Quaternion(-float(q[0]), float(q[1]), -float(q[2]), float(q[3])).normalized()),
		Vector3(float(tr[0]), -float(tr[1]), float(tr[2])) * CM)
	var start := _clip_root(info, _seq_time(info, 0.0))
	var skel := origin * start.affine_inverse() * _clip_root(info, _seq_time(info, t))
	return Transform3D(Mannequin.SKELETON_TURN, Vector3.ZERO) * skel   # skeleton space -> world axes


## CalculateFullAlignedActorRootBoneTransform (yaw only: the floor is level here): the actor turns so
## the reference is in the asset's direction and moves along the line to it to the asset's distance;
## keep_place (the victim, translation weight 1) only turns.
static func _full_aligned(actor: Transform3D, asset_root: Transform3D, actor_ref: Vector3, asset_ref: Vector3, keep_place: bool) -> Transform3D:
	var ref_local := asset_root.affine_inverse() * asset_ref
	var from_asset := actor * ref_local - actor.origin
	var d := actor_ref - actor.origin
	var fa := Vector2(from_asset.x, from_asset.z)
	var fd := Vector2(d.x, d.z)
	if fa.length() < 1e-4 or fd.length() < 1e-4:
		return actor
	var turn := wrapf(atan2(fd.x, fd.y) - atan2(fa.x, fa.y), -PI, PI)
	var basis := Basis(Vector3.UP, turn) * actor.basis
	var pos := actor.origin if keep_place else actor_ref - d * (from_asset.length() / d.length())
	return Transform3D(basis, pos)


## Starts this character's montage (both are started in the same tick, from the same asset time).
func _begin(r: int, other: Node, info: Dictionary, item: Dictionary, aligned: Transform3D, asset_root: Transform3D, t: float) -> void:
	role = r
	partner = other
	montage = info
	montage_time = t
	_ragdolled = false
	_targets.clear()
	# Warp targets: the aligned root moved by the asset's root motion to each window's end.
	for w: Dictionary in info["windows"]:
		var at_end := _asset_root(item, info, w["end"])
		var target := aligned * (asset_root.affine_inverse() * at_end)
		var x := target.basis * Mannequin.SKELETON_TURN.inverse() * Vector3(0, 0, 1)
		_targets.append({"pos": target.origin, "yaw": atan2(x.x, x.z)})
	# Capsules ignore each other (IgnoreComponentWhenMoving, cleared when the montage ends and the
	# ragdoll is over), and the bodies ignore the other capsule.
	character.add_collision_exception_with(other.character)
	_ignoring = other.character
	if ragdoll != null and "body" in ragdoll and ragdoll.body != null:
		for b: PhysicsBody3D in ragdoll.body.bodies:
			b.add_collision_exception_with(other.character)
	character.velocity_cm = Vector3.ZERO
	character.movement_mode = GaspCharacter.MovementMode.ON_GROUND
	character.yaw = matcher.visual_yaw
	matcher.play_action(info["clip"], _seq_time(info, t), info["seq_end"], info["blend_in"], info["play_rate"])


# ------------------------------------------------------------------ per tick

func override_movement(_dt: float) -> bool:
	if role == Role.NONE:
		return false
	var input3 := Vector3(character.move_input.x, 0, character.move_input.y)
	character.acceleration_cm = input3.normalized() * character.max_acceleration * clampf(input3.length(), 0.0, 1.0) if input3.length() > 0.0 else Vector3.ZERO
	return true


func after_animation(dt: float) -> void:
	if role == Role.NONE:
		# ClearMoveIgnoreComponents once neither character is in the interaction or a ragdoll/get-up.
		if _ignoring != null and not is_busy() and (partner == null or not partner.is_busy()):
			if is_instance_valid(_ignoring):
				character.remove_collision_exception_with(_ignoring)
			_ignoring = null
		return
	if ragdoll != null and ragdoll.has_method("is_ragdoll") and ragdoll.is_ragdoll():
		_finish()
		return
	if matcher.action_clip != montage["clip"]:
		_finish()
		return
	var t_now := _montage_time(matcher.blend.get_current_time())
	_apply_root_motion(montage_time, t_now, dt)
	var t_prev := montage_time
	montage_time = t_now
	var rag: Dictionary = montage["ragdoll"]
	if not rag.is_empty() and t_prev < rag["time"] and t_now >= rag["time"] and ragdoll != null:
		# BP_AnimNotify_TriggerRagdoll -> TriggerRagdoll(StopActiveMontages, BlendOut, InjuryState).
		_ragdolled = true
		ragdoll.trigger_ragdoll(rag["stop"], rag["injury"])
		_finish()
		return
	if _should_blend_out(t_now):
		matcher.stop_action()
		_finish()


func _finish() -> void:
	var r := role
	role = Role.NONE
	montage = {}
	interaction_finished.emit(r)


func _should_blend_out(t: float) -> bool:
	# Notifies still fire while a montage blends out; here the action keeps playing until a pending
	# ragdoll notify has fired (shove victims auto-blend-out at 1.083 s, before the notify at 1.103 s).
	var rag: Dictionary = montage["ragdoll"]
	if not rag.is_empty() and t < rag["time"]:
		return false
	var n: Dictionary = montage["blend_out_notify"]
	if role == Role.ATTACKER and not n.is_empty() and t >= n["start"] and t <= n["end"] \
			and not character.acceleration_cm.is_zero_approx():
		return true
	if montage["auto_blend_out"]:
		var trigger: float = montage["blend_out_trigger"]
		var at: float = montage["length"] - (montage["blend_out_time"] if trigger < 0.0 else trigger)
		if t >= at - 1e-4:
			return true
	return t >= montage["length"] - 1e-4


## Root motion from t0 to t1 (montage times), skew-warped toward the window's target (translation
## unless the window has bWarpTranslation off, and yaw), then the mesh follows the capsule.
func _apply_root_motion(t0: float, t1: float, dt: float) -> void:
	if t1 > t0:
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
			var frame := Basis(Vector3.UP, character.yaw) * Mannequin.SKELETON_TURN
			var step := _root_delta(a, b)
			var d: Vector3 = frame * step[0]
			var turn: float = step[1]
			var wi := _window_index(a)
			if wi >= 0:
				var w: Dictionary = montage["windows"][wi]
				var rem := _root_delta(a, w["end"])
				var target: Dictionary = _targets[wi]
				if w["translation"]:
					var r: Vector3 = frame * rem[0]
					var to_target: Vector3 = target["pos"] - character.global_position
					if w["ignore_z"]:
						to_target.y = r.y
					d = _skew_warp(d, r, to_target)
				if w["rotation"]:
					var alpha := clampf((b - a) / maxf((w["end"] - a) * w["rotation_time_multiplier"], 1e-6), 0.0, 1.0)
					var target_rel := wrapf(target["yaw"] - character.yaw, -PI, PI)
					turn += alpha * wrapf(target_rel - rem[1], -PI, PI)
			d.y = 0.0  # the floor holds the capsule (no vertical root motion on level ground)
			character.global_position += d
			character.yaw = wrapf(character.yaw + turn, -PI, PI)
			moved += d
		if dt > 0.0:
			character.velocity = moved / dt
			character.velocity_cm = moved / dt / CM
	matcher.visual_yaw = character.yaw
	matcher.visual.global_position = character.global_position
	matcher.visual.global_basis = Basis(Vector3.UP, character.yaw)


static func _skew_warp(delta: Vector3, remaining: Vector3, to_target: Vector3) -> Vector3:
	var rlen := remaining.length()
	if delta.is_zero_approx():
		return Vector3.ZERO
	if rlen < 1e-5:
		return delta
	var axis := remaining / rlen
	var along := delta.dot(axis)
	return delta - axis * along + to_target * (along / rlen)


func _window_index(t: float) -> int:
	var found := -1
	for i in montage["windows"].size():
		var w: Dictionary = montage["windows"][i]
		if t >= w["start"] - 1e-6 and t < w["end"]:
			found = i
	return found


## Root motion between two montage times: [translation in the root's frame at t0 (m), yaw turn].
func _root_delta(t0: float, t1: float) -> Array:
	var a := _clip_root(montage, _seq_time(montage, t0))
	var b := _clip_root(montage, _seq_time(montage, t1))
	var rel := a.affine_inverse() * b
	var q := rel.basis.get_rotation_quaternion()
	return [rel.origin, 2.0 * atan2(q.z, q.w)]


static func _clip_root(info: Dictionary, seq_t: float) -> Transform3D:
	var anim: Animation = info["anim"]
	var tc := clampf(seq_t, 0.0, anim.length)
	var pos := Vector3.ZERO if info["root_pos"] < 0 else anim.position_track_interpolate(info["root_pos"], tc)
	var rot := Quaternion.IDENTITY if info["root_rot"] < 0 else anim.rotation_track_interpolate(info["root_rot"], tc)
	var xf := Transform3D(Basis(rot), pos)
	# Past the clip's end (the shorter role in a longer asset) the root keeps its last velocity.
	if seq_t > anim.length and anim.length > 0.04:
		var p0 := anim.position_track_interpolate(info["root_pos"], anim.length - 1.0 / 30.0) if info["root_pos"] >= 0 else Vector3.ZERO
		xf.origin += (pos - p0) * ((seq_t - anim.length) * 30.0)
	return xf


static func _seq_time(info: Dictionary, montage_t: float) -> float:
	return info["offset"] + montage_t * info["rate"]


func _montage_time(seq_t: float) -> float:
	return (seq_t - montage["offset"]) / montage["rate"]


# ------------------------------------------------------------------ montage data

## A one-segment montage: its clip, segment mapping, play rate (RateScale x AnimPlayRate), blends,
## warp windows, ragdoll notify and blend-out notify.
static func _montage_info(asset: String) -> Dictionary:
	var infos: Dictionary = _data["infos"]
	if infos.has(asset):
		return infos[asset]
	var mm: Dictionary = _data["montages"][asset]
	var seg: Dictionary = mm["slots"][0]["segments"][0]
	var clip: String = ANIMS + seg["asset"] + ".fbx"
	var lib: AnimationLibrary = load(clip)
	var anim := lib.get_animation(lib.get_animation_list()[0])
	var rate := float(seg.get("AnimPlayRate", 1.0))
	var info := {"asset": asset, "clip": clip, "anim": anim, "length": float(mm["length"]), "rate": rate,
		"offset": float(seg.get("AnimStartTime", 0.0)) - float(seg.get("StartPos", 0.0)) * rate,
		"play_rate": rate * float(mm.get("RateScale", 1.0)),
		"blend_in": float(mm["BlendIn"]["BlendTime"]), "blend_out_time": float(mm["BlendOut"]["BlendTime"]),
		"blend_out_trigger": float(mm.get("BlendOutTriggerTime", -1.0)), "auto_blend_out": bool(mm.get("bEnableAutoBlendOut", true)),
		"windows": [], "ragdoll": {}, "blend_out_notify": {}}
	info["seq_end"] = info["offset"] + info["length"] * rate
	info["root_pos"] = anim.find_track(NodePath("Skeleton3D:root"), Animation.TYPE_POSITION_3D)
	info["root_rot"] = anim.find_track(NodePath("Skeleton3D:root"), Animation.TYPE_ROTATION_3D)
	for n: Dictionary in mm["notifies"]:
		var props: Dictionary = n["object"].get("properties", {})
		match n["class"]:
			"BP_NotifyState_MMI_MotionWarping":
				var p: Dictionary = props.get("RootMotionModifier", {})
				info["windows"].append({"start": float(n["time"]), "end": float(n["end_time"]),
					"translation": bool(p.get("bWarpTranslation", true)), "rotation": bool(p.get("bWarpRotation", true)),
					"ignore_z": bool(p.get("bIgnoreZAxis", true)),
					"rotation_time_multiplier": float(p.get("WarpRotationTimeMultiplier", 1.0))})
			"BP_AnimNotify_TriggerRagdoll":
				info["ragdoll"] = {"time": float(n["time"]), "stop": bool(props.get("Stop Active Montages", true)),
					"injury": String(props.get("Ragdoll Injury State", "NewEnumerator0")).trim_prefix("NewEnumerator").to_int()}
			"BP_NotifyState_MontageBlendOut":
				info["blend_out_notify"] = {"start": float(n["time"]), "end": float(n["end_time"]),
					"time": float(props.get("BlendOutTime", 0.2))}
	info["windows"].sort_custom(func(a, b): return a["start"] < b["start"])
	infos[asset] = info
	return info
