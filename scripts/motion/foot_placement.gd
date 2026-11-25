# The sample's feet: SandboxCharacter_Mover_ABP's Procedural_Feet layer on the clip skeleton (the UEFN
# mannequin's pose, before the retarget onto Manny), as the default level's character runs it:
#  - BlendListByEnum on MovementMode (blend times 0.3 / 0.3 / 0.2 / 0.2 / 0): OnGround -> the Control Rig
#    CR_Biped_FootPlacement (FootPlacement_Enable = a.AnimNode.FootPlacement.Enable, true by default);
#    InAir, Sliding, Traversing -> "BasicIK", a LegIK of foot_l/r onto ik_foot_l/r (ue_leg_ik.gd);
#    Ragdoll -> the pose untouched.
#  - the rig's inputs: Ground Normal (the floor's), DoRaycast true, Enable Foot Pinning = OnGround, Enable
#    Slope Warping = WorldZDamperEnabled = OnGround or Sliding, Has Teleported (moved more than
#    TeleportThreshold 50 cm), ForceReset (one frame when the rig's branch becomes relevant again:
#    Biped_FootPlacement_OnBecomeRelevant), GroundMovementWorldDelta identity (no moving platforms).
# The rig is ported line by line from its graph (extracted/rigs/CR_Biped_FootPlacement.*, written by
# tools/unreal/export_rigs.py and export_rig_hierarchy.py): its hierarchy (bones, nulls,
# controls; setting a global moves children with it), variables and functions, in Unreal component space
# (cm, Z up). Asset quirks are kept (marked QUIRK).
# Runs as a skeleton modifier after the clip-geometry pass and before the retarget. The skeleton runs its
# modifiers twice a frame here (right after the animation advances, and in idle before drawing): the rig
# runs once per physics frame, in the first pass, and the second pass re-applies its result.
extends SkeletonModifier3D

const LEG_IK := preload("res://scripts/motion/ue_leg_ik.gd")
const RETARGET := preload("res://scripts/motion/retarget.gd")
const SEQUENCES := "res://extracted/data/sequences.json"

# ABP Procedural_Feet BlendListByEnum (E_MovementMode order: OnGround, InAir, Sliding, Traversing, Ragdoll).
enum Branch { RIG, BASIC_IK, RAW }
const BLEND_TIMES := {"OnGround": 0.3, "InAir": 0.3, "Sliding": 0.2, "Traversing": 0.2, "Ragdoll": 0.0}
const TELEPORT_THRESHOLD := 50.0   # cm, SandboxCharacter_Mover_ABP TeleportThreshold (MDEF:L435)

# Rig variables (CR_Biped_FootPlacement CDO, defaults.t3d:114-160).
const MAX_FOOT_PIN_RADIUS := 40.0
const CLAMP_FOOT_MIN_HEIGHT_TO_REFERENCE := false
const FOOT_CONTACT_LOCK_THRESHOLD := 0.97
const PIN_YAW_LIMIT_DEGREES := 0.0
const ALLOW_HEEL_LIFT := true
const TOE_LENGTH := 5.0
const HYPER_EXTENSION_LIMIT_FACTOR := 0.98
const PELVIS_SMOOTHING_TIME := 0.2
const PIN_BLEND_OUT_SMOOTHING_TIME := 0.2
const HEEL_UP_ANGLE_START := 15.0
const HEEL_UP_ANGLE_END := 25.0
const FLOOR_SMOOTHING_TIME := 0.05
const USE_IK_BONE_TARGETS := true
const ROOT_DAMPER_SMOOTHING_TIME := 0.15
const ADJUST_FEET_TARGETS_FOR_COLLISION := false
const SLOPE_ANGLE_LIMIT_DEGREES := 45.0   # Update Floor Control local
const SCENE_HEIGHT_OFFSET := 50.0         # Do Scene Query locals
const SPHERE_CAST_RADIUS := 5.0

## Set by the matcher every frame: E_MovementMode name ("OnGround", "InAir", "Sliding", "Traversing",
## "Ragdoll"), the floor normal (Godot world) and the blended contact curves.
var movement_mode := "OnGround"
var ground_normal := Vector3.UP
## The character's collision object, ignored by the traces.
var exclude: Array[RID] = []
var contact := [0.0, 0.0]

static var _contact_curves := {}

# Branch weights of the BlendListByEnum (index: Branch), crossfaded linearly.
var _weights := [0.0, 0.0, 1.0]
var _rig_relevant := false
var _started := false        # the first frame starts on the active branch (no blend in)
var _force_reset := false
var _last_ctw_origin := Vector3.INF
var _legs_basic := [LEG_IK.new(), LEG_IK.new()]
# Result cache: the first pass of a physics frame computes, later passes re-apply.
var _cache_frame := -1
var _cache := {}             # bone -> local Transform3D (Godot skeleton space)

# ------------------------------------------------------------------ rig state

var _built := false
var _n := 0                         # element count (bones first, then nulls/controls)
var _parent := PackedInt32Array()
var _children: Array = []
var _g: Array[Transform3D] = []     # current global (component space, cm)
var _gi: Array[Transform3D] = []    # initial global
var _id := {}                       # name -> element
var _bone_count := 0

var left_leg_length := 0.0
var right_leg_length := 0.0
var foot_to_toe_axis := [Vector3.ZERO, Vector3.ZERO]
var foot_pinned := [false, false]
var pin_weight := [0.0, 0.0]
var pin_transform_world := [Transform3D.IDENTITY, Transform3D.IDENTITY]
var pin_anim_transform_world := [Transform3D.IDENTITY, Transform3D.IDENTITY]
var pelvis_offset := Vector3.ZERO
var world_z_damper := 0.0
var world_z_damper_velocity := 0.0
var world_z_damper_alpha := 0.0
var smooth_ground_world := [Transform3D.IDENTITY, Transform3D.IDENTITY]
var slope_warping_alpha := 0.0
var pending_reset := false
var world_prev_transform := Transform3D.IDENTITY
# Per-frame inputs.
var _enable_foot_pinning := false
var _enable_slope_warping := false
var _world_z_damper_enabled := false
var _has_teleported := false
var _ctw := Transform3D.IDENTITY     # component (cm) -> Unreal world (cm)
var _ground_normal_ue := Vector3.ZERO
var _dt := 0.0

# Nulls and controls of the rig hierarchy (CR_Biped_FootPlacement.hierarchy.txt): name, parent, initial
# global (Unreal, cm). Every *_ctrl is a child of its *_null with identity local.
const NULLS := [
	["calculated_toe_target_l_null", "root"], ["calculated_toe_target_r_null", "root"],
	["pelvis_null", "root"], ["toe_l_null", "root"], ["toe_r_null", "root"],
	["clamped_toe_l_null", "toe_r_null"], ["clamped_foot_l_null", "toe_r_null"],   # QUIRK: under toe_r_null
	["foot_l_null", "root"], ["clamped_toe_r_null", "root"], ["clamped_foot_r_null", "root"],
	["foot_r_null", "root"], ["smoothed_floor_l_null", "root"], ["smoothed_floor_r_null", "root"],
	["animated_slope_angle_null", "root"],
	["animated_toe_target_l_null", ""], ["animated_toe_target_r_null", ""], ["animated_pelvis_null", ""],
]
const CONTROLS_UNPARENTED := ["floor_l_collision", "floor_r_collision"]


# ------------------------------------------------------------------ Unreal space

## Godot skeleton space (m, the bone frames are Unreal's with Y negated) <-> Unreal component space (cm).
static func to_ue(t: Transform3D) -> Transform3D:
	var m := Basis(Vector3(1, 0, 0), Vector3(0, -1, 0), Vector3(0, 0, 1))
	return Transform3D(m * t.basis.orthonormalized() * m, m * t.origin * 100.0)


static func from_ue(t: Transform3D) -> Transform3D:
	var m := Basis(Vector3(1, 0, 0), Vector3(0, -1, 0), Vector3(0, 0, 1))
	return Transform3D(m * t.basis * m, m * t.origin * 0.01)


## Godot world -> Unreal world (cm, Z up): the skeleton's turn and the Y mirror, undone.
static func world_to_ue() -> Transform3D:
	var m := Basis(Vector3(1, 0, 0), Vector3(0, -1, 0), Vector3(0, 0, 1))
	return Transform3D(m * Mannequin.SKELETON_TURN.inverse() * 100.0, Vector3.ZERO)


# ------------------------------------------------------------------ inputs from the matcher

static func _curves() -> Dictionary:
	if _contact_curves.is_empty():
		var seqs: Dictionary = JSON.parse_string(FileAccess.get_file_as_string(SEQUENCES))
		for seq: String in seqs:
			var found := {}
			for c: Dictionary in seqs[seq].get("curves", []):
				var nm := String(c["name"]).to_lower()
				if nm == "contact_l" or nm == "contact_r":
					found[nm] = c
			if not found.is_empty():
				_contact_curves[seq] = found
	return _contact_curves


## The clips' contact_l / contact_r, blended by the blend stack's weights (a clip without the curve
## counts as 0, a missing curve is 0: RigUnit_GetCurveValue).
func update_contacts(players: Array, sequence_of: Dictionary) -> void:
	var curves := _curves()
	for k in 2:
		var nm: String = ["contact_l", "contact_r"][k]
		var v := 0.0
		for p: Array in players:
			var seq: Dictionary = curves.get(sequence_of.get(p[0], ""), {})
			if seq.has(nm):
				v += _eval_linear(seq[nm], p[1]) * float(p[2])
		contact[k] = v


static func _eval_linear(c: Dictionary, t: float) -> float:
	var times: Array = c["times"]
	var vals: Array = c["values"]
	if times.is_empty():
		return 0.0
	if t <= times[0]:
		return vals[0]
	if t >= times[-1]:
		return vals[-1]
	var i := 1
	while times[i] < t:
		i += 1
	var mode = c.get("interp", "RCIM_Linear")
	if mode is Array:
		mode = mode[i - 1]
	if mode == "RCIM_Constant":
		return vals[i - 1]
	return lerpf(vals[i - 1], vals[i], (t - times[i - 1]) / (times[i] - times[i - 1]))


# ------------------------------------------------------------------ modifier

func _process_modification_with_delta(delta: float) -> void:
	var sk := get_skeleton()
	if sk == null:
		return
	if not _built:
		_build(sk)
	var frame := Engine.get_physics_frames()
	if frame == _cache_frame:
		for b: int in _cache:
			sk.set_bone_pose_position(b, (_cache[b] as Transform3D).origin)
			sk.set_bone_pose_rotation(b, (_cache[b] as Transform3D).basis.get_rotation_quaternion())
		return
	_cache_frame = frame
	_cache.clear()
	var dt := delta if delta > 0.0 else get_physics_process_delta_time()
	_step_branches(dt)
	# The pose in, Unreal component space.
	for b in _bone_count:
		_g[b] = to_ue(sk.get_bone_global_pose(b))
	var input: Array[Transform3D] = _g.slice(0, _bone_count)
	var out_rig: Array[Transform3D] = []
	var out_basic: Array[Transform3D] = []
	_ctw = world_to_ue() * sk.global_transform * Transform3D(Basis(Vector3(0.01, 0, 0), Vector3(0, -0.01, 0), Vector3(0, 0, 0.01)), Vector3.ZERO)
	_ctw = _ctw.orthonormalized()
	if _weights[Branch.RIG] > 0.0:
		if not _rig_relevant:
			_force_reset = true   # Biped_FootPlacement_OnBecomeRelevant -> ForceFootPlacementReset
		_rig_relevant = true
		_forwards_solve(dt)
		out_rig = _g.slice(0, _bone_count)
		for b in _bone_count:
			_g[b] = input[b]
	else:
		_rig_relevant = false
	_force_reset = false
	if _weights[Branch.BASIC_IK] > 0.0:
		_basic_ik()
		out_basic = _g.slice(0, _bone_count)
		for b in _bone_count:
			_g[b] = input[b]
	_last_ctw_origin = _ctw.origin
	# Blend the branches' local poses (BlendListByEnum: weights per branch, local space) and write the
	# bones the branches change.
	var touched := _touched_bones()
	for b in touched:
		var p := _parent[b]
		var loc_in := _local(input, b, p)
		var w_raw: float = _weights[Branch.RAW]
		var pos: Vector3 = loc_in.origin * w_raw
		var q := loc_in.basis.get_rotation_quaternion()
		var acc: Quaternion = q * w_raw
		for br in [Branch.RIG, Branch.BASIC_IK]:
			var w: float = _weights[br]
			if w <= 0.0:
				continue
			var lt := _local(out_rig if br == Branch.RIG else out_basic, b, p)
			pos += lt.origin * w
			var lq := lt.basis.get_rotation_quaternion()
			if lq.dot(q) < 0.0:
				lq = -lq
			acc += lq * w
		var local := Transform3D(Basis(acc.normalized()), pos)
		var gl := from_ue(local)
		_cache[b] = gl
		sk.set_bone_pose_position(b, gl.origin)
		sk.set_bone_pose_rotation(b, gl.basis.get_rotation_quaternion())


func _local(pose: Array[Transform3D], b: int, p: int) -> Transform3D:
	return pose[b] if p < 0 else pose[p].affine_inverse() * pose[b]


func _touched_bones() -> Array[int]:
	var out: Array[int] = []
	for nm in ["root", "pelvis", "thigh_l", "calf_l", "foot_l", "ball_l", "thigh_r", "calf_r", "foot_r", "ball_r"]:
		out.append(_id[nm])
	return out


## BlendListByEnum: the active child's weight goes to 1 over its blend time, the others to 0.
func _step_branches(dt: float) -> void:
	var target := Branch.RAW
	match movement_mode:
		"OnGround":
			target = Branch.RIG
		"InAir", "Sliding", "Traversing":
			target = Branch.BASIC_IK
	var bt: float = BLEND_TIMES.get(movement_mode, 0.0)
	var step := 1.0 if bt <= 0.0 or not _started else dt / bt
	_started = true
	for i in 3:
		var goal := 1.0 if i == target else 0.0
		_weights[i] = move_toward(_weights[i], goal, step)
	var s: float = _weights[0] + _weights[1] + _weights[2]
	for i in 3:
		_weights[i] /= s
	_enable_foot_pinning = movement_mode == "OnGround"
	_enable_slope_warping = movement_mode == "OnGround" or movement_mode == "Sliding"
	_world_z_damper_enabled = _enable_slope_warping


# ------------------------------------------------------------------ hierarchy

func _build(sk: Skeleton3D) -> void:
	_built = true
	_bone_count = sk.get_bone_count()
	for b in _bone_count:
		_id[sk.get_bone_name(b)] = b
		_parent.append(sk.get_bone_parent(b))
	# Initial (reference) pose of the bones: the UEFN mannequin's, from Unreal (retarget.json source_ref,
	# local transforms in Unreal space).
	var ref: Dictionary = RETARGET.data()["source_ref"]
	var locals: Array[Transform3D] = []
	for b in _bone_count:
		var e = ref.get(sk.get_bone_name(b))
		if e == null:
			locals.append(Transform3D.IDENTITY)
		else:
			var q := Quaternion(e["q"][0], e["q"][1], e["q"][2], e["q"][3]).normalized()
			locals.append(Transform3D(Basis(q), Vector3(e["t"][0], e["t"][1], e["t"][2])))
	_g.resize(_bone_count)
	_gi.resize(_bone_count)
	for b in _bone_count:
		var p := _parent[b]
		_gi[b] = locals[b] if p < 0 else _gi[p] * locals[b]
		_g[b] = _gi[b]
	for e in NULLS:
		_add(e[0], e[1])
		_add(String(e[0]).trim_suffix("_null") + "_ctrl", e[0])
	for c in CONTROLS_UNPARENTED:
		_add(c, "")
	_children.resize(_n)
	for i in _n:
		_children[i] = []
	for i in _n:
		if _parent[i] >= 0:
			_children[_parent[i]].append(i)
	_construction()


func _add(nm: String, parent_name: String) -> void:
	if _n == 0:
		_n = _bone_count
	var p: int = _id.get(parent_name, -1) if parent_name != "" else -1
	_id[nm] = _n
	_parent.append(p)
	var g := _g[p] if p >= 0 else Transform3D.IDENTITY
	_g.append(g)
	_gi.append(g)
	_n += 1


func G(e: String) -> Transform3D:
	return _g[_id[e]]


func GI(e: String) -> Transform3D:
	return _gi[_id[e]]


## SetGlobalTransform with affect children: children keep their local transform.
func setG(e: String, t: Transform3D) -> void:
	_set_global(_id[e], Transform3D(t.basis.orthonormalized(), t.origin))


func _set_global(i: int, t: Transform3D) -> void:
	var old := _g[i]
	_g[i] = t
	if not _children.is_empty():
		for c: int in _children[i]:
			_set_global(c, t * (old.affine_inverse() * _g[c]))


func setT(e: String, v: Vector3) -> void:
	var t := G(e)
	setG(e, Transform3D(t.basis, v))


func setR(e: String, q: Quaternion) -> void:
	var t := G(e)
	setG(e, Transform3D(Basis(q.normalized()), t.origin))


static func rq(t: Transform3D) -> Quaternion:
	return t.basis.get_rotation_quaternion()


static func xf(r: Quaternion, t: Vector3) -> Transform3D:
	return Transform3D(Basis(r.normalized()), t)


## Get Relative Transform: child in the parent's frame (Unreal c * inverse(p)), rotation normalized.
static func rel_of(c: Transform3D, p: Transform3D) -> Transform3D:
	var r := p.affine_inverse() * c
	return Transform3D(r.basis.orthonormalized(), r.origin)


func rel(c: String, p: String) -> Transform3D:
	return rel_of(G(c), G(p))


func relI(c: String, p: String) -> Transform3D:
	return rel_of(GI(c), GI(p))


static func axis_z(q: Quaternion) -> Vector3:
	return q * Vector3(0, 0, 1)


# World <-> component (ExecuteContext.ToWorldSpaceTransform).
func toW(t: Transform3D) -> Transform3D:
	return _ctw * t


func fromW(t: Transform3D) -> Transform3D:
	return _ctw.affine_inverse() * t


func toWp(p: Vector3) -> Vector3:
	return _ctw * p


func fromWp(p: Vector3) -> Vector3:
	return _ctw.affine_inverse() * p


func toWq(q: Quaternion) -> Quaternion:
	return rq(_ctw) * q


func fromWq(q: Quaternion) -> Quaternion:
	return rq(_ctw).inverse() * q


# ------------------------------------------------------------------ math units

static func inv_exp_approx(x: float) -> float:
	return 1.0 / (1.0 + 1.00746054 * x + 0.45053901 * x * x + 0.25724632 * x * x * x)


func damp_float(value: float, target: float, smoothing: float) -> float:
	if smoothing > 1e-4:
		return target + (value - target) * inv_exp_approx(_dt / smoothing)
	return target


func damp_vector(value: Vector3, target: Vector3, smoothing: float) -> Vector3:
	if smoothing > 1e-4:
		return target + (value - target) * inv_exp_approx(_dt / smoothing)
	return target


func damp_quat(value: Quaternion, target: Quaternion, smoothing: float) -> Quaternion:
	if smoothing > 1e-8:
		return ue_slerp(value, target, 1.0 - inv_exp_approx(_dt / smoothing))
	return target


## FQuat::Slerp (shortest path, linear weights when nearly parallel, normalized).
static func ue_slerp(a: Quaternion, b: Quaternion, t: float) -> Quaternion:
	var raw_cos := a.dot(b)
	var cosom := absf(raw_cos)
	var s0: float
	var s1: float
	if cosom < 0.9999:
		var omega := acos(cosom)
		var inv_sin := 1.0 / sin(omega)
		s0 = sin((1.0 - t) * omega) * inv_sin
		s1 = sin(t * omega) * inv_sin
	else:
		s0 = 1.0 - t
		s1 = t
	s1 = s1 if raw_cos >= 0.0 else -s1
	var q := Quaternion(s0 * a.x + s1 * b.x, s0 * a.y + s1 * b.y, s0 * a.z + s1 * b.z, s0 * a.w + s1 * b.w)
	return q.normalized()


static func nearly_zero_v(v: Vector3, tol := 1e-4) -> bool:
	return absf(v.x) <= tol and absf(v.y) <= tol and absf(v.z) <= tol


static func safe_normal(v: Vector3) -> Vector3:
	return Vector3.ZERO if v.length_squared() < 1e-8 else v.normalized()


## RigVMMathLibrary FindQuatBetweenVectors.
static func find_quat_between(a: Vector3, b: Vector3) -> Quaternion:
	var na := safe_normal(a)
	var nb := safe_normal(b)
	var w := 1.0 + na.dot(nb)
	if w < 1e-8:
		var n := Vector3(0, 1, 0) if absf(na.x) > absf(na.y) else Vector3(1, 0, 0)
		var axis := na.cross(na.cross(n)).normalized()
		return Quaternion(axis, PI) if axis != Vector3.ZERO else Quaternion.IDENTITY
	var c := na.cross(nb)
	return Quaternion(c.x, c.y, c.z, w).normalized()


static func from_two_vectors(a: Vector3, b: Vector3) -> Quaternion:
	if nearly_zero_v(a) or nearly_zero_v(b):
		return Quaternion.IDENTITY
	return find_quat_between(a, b)


static func unit(v: Vector3) -> Vector3:
	return Vector3.ZERO if nearly_zero_v(v) else v.normalized()


static func clamp_length(v: Vector3, lo: float, hi: float) -> Vector3:
	if nearly_zero_v(v):
		return Vector3.ZERO
	var l := v.length()
	return v * clampf(l, lo, hi) / l


static func set_length(v: Vector3, length: float) -> Vector3:
	return Vector3.ZERO if nearly_zero_v(v) else v.normalized() * length


static func angle_between(a: Vector3, b: Vector3) -> float:
	if nearly_zero_v(a) or nearly_zero_v(b):
		return 0.0
	var q := find_quat_between(a, b)
	return 2.0 * acos(clampf(q.w, -1.0, 1.0))


static func intersect_plane(start: Vector3, dir: Vector3, point: Vector3, normal: Vector3) -> Vector3:
	var n := normal.normalized() if normal.length_squared() >= 1e-8 else Vector3(0, 0, 1)
	var d := dir.dot(n)
	if absf(d) <= 1e-8:
		return Vector3.ZERO
	return start + dir * ((point.dot(n) - start.dot(n)) / d)


static func closest_on_plane(p: Vector3, point: Vector3, normal: Vector3) -> Vector3:
	var n := safe_normal(normal)
	if n == Vector3.ZERO:
		return Vector3.ZERO
	return p - n * (p.dot(n) - point.dot(n))


static func remap_clamped(v: float, smin: float, smax: float, tmin: float, tmax: float) -> float:
	var r := 0.0 if absf(smax - smin) < 1e-8 else (v - smin) / (smax - smin)
	return lerpf(tmin, tmax, clampf(r, 0.0, 1.0))


static func cubic_ease_in_out(p: float) -> float:
	if p < 0.5:
		return 4.0 * p * p * p
	var f := 2.0 * p - 2.0
	return 0.5 * f * f * f + 1.0


static func lerp_transform(a: Transform3D, b: Transform3D, t: float) -> Transform3D:
	return xf(ue_slerp(rq(a), rq(b), t), a.origin.lerp(b.origin, t))


## RigUnit_SetTranslation / SetTransform with a weight: < 1e-8 does nothing, < 1 blends.
func set_translation_weighted(e: String, v: Vector3, weight: float) -> void:
	if weight < 1e-8:
		return
	var cur := G(e)
	var nw := Transform3D(cur.basis, v)
	setG(e, nw if weight >= 1.0 - 1e-8 else lerp_transform(cur, nw, weight))


## RigUnit_AimItem, primary target only (location kind, global target).
func aim_item(e: String, axis_local: Vector3, target: Vector3) -> void:
	var r := G(e)
	var tgt := target - r.origin
	if nearly_zero_v(tgt) or nearly_zero_v(axis_local):
		return
	tgt = safe_normal(tgt)
	var axis := safe_normal(rq(r) * axis_local)
	setG(e, Transform3D(Basis((find_quat_between(axis, tgt) * rq(r)).normalized()), r.origin))


# ------------------------------------------------------------------ Construction Event (3.2)

func _construction() -> void:
	# The pose is the reference pose (current = initial) while it runs.
	for i in _n:
		_g[i] = _gi[i]
	_init_leg("smoothed_floor_r_null", "toe_l_null", "ball_l")   # QUIRK: the left call passes the right floor
	_init_leg("smoothed_floor_r_null", "toe_r_null", "ball_r")
	setG("pelvis_null", GI("pelvis"))
	left_leg_length = relI("calf_l", "thigh_l").origin.length() + relI("foot_l", "calf_l").origin.length()
	right_leg_length = relI("calf_r", "thigh_r").origin.length() + relI("foot_r", "calf_r").origin.length()
	foot_to_toe_axis[0] = unit(relI("ball_l", "foot_l").origin)
	foot_to_toe_axis[1] = unit(relI("ball_r", "foot_r").origin)
	# Bones, controls and curves go back to the input pose afterwards (nulls keep what this wrote); the
	# controls' Set Translation here has no lasting effect.


func _init_leg(floor_null: String, toe_null: String, toe_bone: String) -> void:
	setG(toe_null, G(toe_bone))
	_gi[_id[toe_null]] = G(toe_null)
	var f := G(floor_null)
	var t := G(toe_null)
	var v := Transform3D(f.basis, Vector3(t.origin.x, t.origin.y, 0.0))
	setG(floor_null, v)
	_gi[_id[floor_null]] = v


# ------------------------------------------------------------------ Forwards Solve (3.3)

func _forwards_solve(dt: float) -> void:
	_dt = dt
	_ground_normal_ue = (world_to_ue().basis * ground_normal) / 100.0
	_has_teleported = _last_ctw_origin.is_finite() and _ctw.origin.distance_squared_to(_last_ctw_origin) > TELEPORT_THRESHOLD * TELEPORT_THRESHOLD
	if _check_early_out():
		pending_reset = true
		return
	# B
	if (_has_teleported or pending_reset) or _force_reset:
		_reset()
	setR("animated_slope_angle_null", rq(G("ik_foot_root")))
	# C
	setG("animated_toe_target_l_null", _target_animated_toe("ball_l", "foot_l", "ik_foot_l"))
	setG("animated_toe_target_r_null", _target_animated_toe("ball_r", "foot_r", "ik_foot_r"))
	setG("animated_pelvis_null", G("pelvis"))
	# D
	_update_root_damper()
	# E (DoRaycast is true in the ABP)
	if _enable_slope_warping:
		_do_scene_query("floor_l_collision", "animated_toe_target_l_null", contact[0])
		_do_scene_query("floor_r_collision", "animated_toe_target_r_null", contact[1])
	else:
		setG("floor_l_collision", GI("floor_l_collision"))
		setG("floor_r_collision", GI("floor_r_collision"))
	# F
	smooth_ground_world[0] = _update_floor_control("smoothed_floor_l_null", "floor_l_collision", smooth_ground_world[0])
	smooth_ground_world[1] = _update_floor_control("smoothed_floor_r_null", "floor_r_collision", smooth_ground_world[1])
	# G
	_update_foot_pinning(0, contact[0], "animated_toe_target_l_ctrl")
	_update_foot_pinning(1, contact[1], "animated_toe_target_r_ctrl")
	# H
	_update_leg_controls(0, "smoothed_floor_l_ctrl", "toe_l_null", "toe_l_ctrl", "foot_l", "ball_l",
		Vector3(1, 0, 0), "calculated_toe_target_l_null", "calculated_toe_target_l_ctrl", "foot_l_null",
		Vector3(0, -1, 0), "animated_toe_target_l_ctrl")
	_update_leg_controls(1, "smoothed_floor_r_ctrl", "toe_r_null", "toe_r_ctrl", "foot_r", "ball_r",
		Vector3(-1, 0, 0), "calculated_toe_target_r_null", "calculated_toe_target_r_ctrl", "foot_r_null",
		Vector3(0, 1, 0), "animated_toe_target_r_ctrl")
	_update_pelvis_control()
	# I
	setG("pelvis", G("pelvis_ctrl"))
	_solve_leg_ik("thigh_l", "calf_l", "foot_l", "foot_l_ctrl", Vector3(-1, 0, 0), Vector3(0, 1, 0),
		left_leg_length, "toe_l_ctrl", "clamped_foot_l_null", "clamped_foot_l_ctrl", "clamped_toe_l_null", foot_to_toe_axis[0])
	_solve_leg_ik("thigh_r", "calf_r", "foot_r", "foot_r_ctrl", Vector3(1, 0, 0), Vector3(0, -1, 0),
		right_leg_length, "toe_r_ctrl", "clamped_foot_r_null", "clamped_foot_r_ctrl", "clamped_toe_r_null", foot_to_toe_axis[1])
	# J
	_update_foot_post_solve("foot_l", "ball_l", "smoothed_floor_l_ctrl", "calculated_toe_target_l_ctrl", Vector3(1, 0, 0), foot_to_toe_axis[0])
	_update_foot_post_solve("foot_r", "ball_r", "smoothed_floor_r_ctrl", "calculated_toe_target_r_ctrl", Vector3(-1, 0, 0), foot_to_toe_axis[1])
	# K
	world_prev_transform = toW(Transform3D.IDENTITY)


# 4.20
func _check_early_out() -> bool:
	return (not _enable_foot_pinning) and (not _enable_slope_warping) and (not _world_z_damper_enabled) \
		and absf(slope_warping_alpha) <= 0.01 and absf(world_z_damper_alpha) <= 0.01 \
		and absf(pin_weight[0]) <= 0.01 and absf(pin_weight[1]) <= 0.01 \
		and ((not USE_IK_BONE_TARGETS) or (nearly_zero_v(G("foot_l").origin - G("ik_foot_l").origin, 0.5) \
			and nearly_zero_v(G("foot_r").origin - G("ik_foot_r").origin, 0.5)))


# 4.19
func _reset() -> void:
	pelvis_offset = Vector3.ZERO
	foot_pinned = [false, false]
	pin_weight = [0.0, 0.0]
	setG("floor_l_collision", GI("floor_l_collision"))
	setG("smoothed_floor_r_null", GI("floor_l_collision"))   # QUIRK: should be the left null
	setG("floor_r_collision", GI("floor_r_collision"))
	setG("smoothed_floor_r_null", GI("floor_r_collision"))
	world_z_damper_velocity = 0.0
	world_z_damper = toWp(Vector3.ZERO).z
	smooth_ground_world[0] = toW(GI("floor_l_collision"))
	smooth_ground_world[1] = toW(GI("floor_r_collision"))
	world_prev_transform = toW(Transform3D.IDENTITY)
	pending_reset = false


# 4.12
func _target_animated_toe(toe: String, foot: String, ik: String) -> Transform3D:
	if not USE_IK_BONE_TARGETS:
		return G(toe)
	# Unreal (rel(toe, foot) * rel(ik, foot)) * G(foot).
	return G(foot) * rel(ik, foot) * rel(toe, foot)


# 4.21
func _update_root_damper() -> void:
	# A: ground movement delta is identity.
	world_z_damper_alpha = damp_float(world_z_damper_alpha, 1.0 if _world_z_damper_enabled else 0.0, 0.05)
	if world_z_damper_alpha > 0.01:
		var disp := toWp(Vector3.ZERO) - world_prev_transform.origin
		var d := disp.dot(_ground_normal_ue)
		var along := disp - _ground_normal_ue * d
		world_z_damper = along.z + world_z_damper
		# Critical Spring Damp (Float).
		var target := toWp(Vector3.ZERO).z
		var st := ROOT_DAMPER_SMOOTHING_TIME
		if st < 1e-8:
			world_z_damper = target
			world_z_damper_velocity = 0.0
		else:
			var y := (4.0 / maxf(st, 1e-8)) / 2.0
			var j0 := world_z_damper - target
			var j1 := world_z_damper_velocity + j0 * y
			var e := inv_exp_approx(y * _dt)
			world_z_damper = e * (j0 + j1 * _dt) + target
			world_z_damper_velocity = e * (world_z_damper_velocity - j1 * y * _dt)
		var z_rig := fromWp(Vector3(0, 0, world_z_damper)).z
		var root := G("root")
		set_translation_weighted("root", Vector3(root.origin.x, root.origin.y, z_rig), world_z_damper_alpha)
	else:
		world_z_damper = toWp(Vector3.ZERO).z
		world_z_damper_velocity = 0.0


# 4.7
func _do_scene_query(floor_collision: String, animated_target: String, contact_w: float) -> void:
	var att := G(animated_target)
	var r1_start := Vector3(0, 0, SCENE_HEIGHT_OFFSET)
	var r1_end := Vector3(att.origin.x, att.origin.y, SCENE_HEIGHT_OFFSET)
	var h1 := _sphere_trace(r1_start, r1_end, SPHERE_CAST_RADIUS)
	var s: Vector3 = h1["location"] - h1["normal"] * (SPHERE_CAST_RADIUS * -2.0)
	if ADJUST_FEET_TARGETS_FOR_COLLISION and h1["hit"]:
		setG(animated_target, Transform3D(att.basis, Vector3(s.x, s.y, att.origin.z)))
	var r2_start: Vector3 = s if h1["hit"] else r1_end
	var r2_end := r2_start - Vector3(0, 0, SCENE_HEIGHT_OFFSET * 2.0)
	var h2 := _sphere_trace(r2_start, r2_end, 5.0)
	if h2["hit"]:
		setT(floor_collision, h2["location"])
		var gn := rq(_ctw).inverse() * (_ground_normal_ue.normalized() if _ground_normal_ue.length_squared() > 1e-12 else Vector3(1, 0, 0))
		var n := gn.lerp(h2["normal"], contact_w)
		setR(floor_collision, from_two_vectors(Vector3(0, 0, 1), n))


## SphereTraceByTraceChannel (Visibility): a sphere swept from start to end (component space, cm) through
## the world; the contact point and normal on a hit, else (0,0,0) and (0,0,1).
func _sphere_trace(start: Vector3, end: Vector3, radius: float) -> Dictionary:
	var miss := {"hit": false, "location": Vector3.ZERO, "normal": Vector3(0, 0, 1)}
	var sk := get_skeleton()
	var space := sk.get_world_3d().direct_space_state
	var w2u := world_to_ue()
	var u2w := w2u.affine_inverse()
	var a := u2w * toWp(start)
	var b := u2w * toWp(end)
	var params := PhysicsShapeQueryParameters3D.new()
	var sphere := SphereShape3D.new()
	sphere.radius = radius * 0.01
	params.shape = sphere
	params.collision_mask = 1
	params.exclude = exclude
	params.transform = Transform3D(Basis.IDENTITY, a)
	params.motion = b - a
	var r := space.cast_motion(params)
	if r.size() < 2 or r[1] >= 1.0:
		return miss
	params.transform = Transform3D(Basis.IDENTITY, a + (b - a) * r[1])
	params.motion = Vector3.ZERO
	var info := space.get_rest_info(params)
	if info.is_empty():
		return miss
	var p_ue := fromWp(w2u * (info["point"] as Vector3))
	var n_ue := (rq(_ctw).inverse() * (w2u.basis * (info["normal"] as Vector3))).normalized()
	return {"hit": true, "location": p_ue, "normal": n_ue}


# 4.6
func _update_floor_control(floor_null: String, floor_collision: String, sgt: Transform3D) -> Transform3D:
	# A: identity ground delta.
	# B (QUIRK: runs for each leg, so it is damped twice a frame)
	slope_warping_alpha = damp_float(slope_warping_alpha, 1.0 if _enable_slope_warping else 0.0, 0.2)
	# C
	var tgt_w := toWp(G(floor_collision).origin)
	var damp_w := damp_vector(sgt.origin, tgt_w, FLOOR_SMOOTHING_TIME)
	setT(floor_null, Vector3.ZERO.lerp(fromWp(damp_w), slope_warping_alpha))
	sgt = Transform3D(sgt.basis, damp_w)
	# D
	var up := axis_z(rq(G(floor_collision)))
	var ang := angle_between(Vector3(0, 0, 1), up)
	var lim := deg_to_rad(SLOPE_ANGLE_LIMIT_DEGREES)
	var nrm := up
	if ang > lim:
		nrm = set_length(Vector3(up.x, up.y, 0.0), sin(lim)) + Vector3(0, 0, cos(lim))
	var q := from_two_vectors(Vector3(0, 0, 1), nrm)
	var damp_q := damp_quat(rq(sgt), toWq(q), FLOOR_SMOOTHING_TIME)
	setR(floor_null, ue_slerp(Quaternion.IDENTITY, fromWq(damp_q), slope_warping_alpha))
	return Transform3D(Basis(damp_q), sgt.origin)


# 4.8
func _wants_to_lock(contact_w: float) -> bool:
	return _enable_foot_pinning and contact_w >= FOOT_CONTACT_LOCK_THRESHOLD


# 4.10
func _update_foot_pinning(k: int, contact_w: float, animated_toe_ctrl: String) -> void:
	var atg := G(animated_toe_ctrl)
	# A: identity ground delta leaves the pins as they are.
	var wants := _wants_to_lock(contact_w)
	if foot_pinned[k]:
		if not wants:
			foot_pinned[k] = false
		else:
			pin_anim_transform_world[k] = toW(atg)
			var pt: Transform3D = pin_transform_world[k]
			pt = Transform3D(pt.basis, Vector3(pt.origin.x, pt.origin.y, toW(atg).origin.z))
			pin_transform_world[k] = pt
			var p := fromW(pt)
			var dxy := Vector3(p.origin.x - atg.origin.x, p.origin.y - atg.origin.y, 0.0)
			var cxy := clamp_length(dxy, 0.0, MAX_FOOT_PIN_RADIUS)
			var p_w := toWp(cxy + atg.origin)
			var a := axis_z(rq(atg))
			var b := axis_z(rq(p))
			var q := from_two_vectors(Vector3(a.x, a.y, 0.0), Vector3(b.x, b.y, 0.0))
			var aa := _to_axis_angle(q)
			var ang_c := deg_to_rad(clampf(rad_to_deg(aa[1]), -PIN_YAW_LIMIT_DEGREES, PIN_YAW_LIMIT_DEGREES))
			var yaw_q := Quaternion.IDENTITY if nearly_zero_v(aa[0]) else Quaternion((aa[0] as Vector3).normalized(), ang_c)
			var r_w := toWq(yaw_q * rq(atg))
			pin_transform_world[k] = xf(r_w, Vector3(p_w.x, p_w.y, pt.origin.z))
	else:
		if absf(pin_weight[k]) <= 0.5 and wants:
			if absf(pin_weight[k]) <= 0.01:
				pin_transform_world[k] = toW(atg)
			else:
				pin_transform_world[k] = toW(_pinned_toe_target(pin_transform_world[k], pin_anim_transform_world[k], atg, pin_weight[k]))
			pin_anim_transform_world[k] = toW(atg)
			pin_weight[k] = 1.0
			foot_pinned[k] = true
		else:
			var speed := 1.0 / PIN_BLEND_OUT_SMOOTHING_TIME if PIN_BLEND_OUT_SMOOTHING_TIME > 0.0001 else 0.0
			pin_weight[k] = _alpha_linear_interp(pin_weight[k], speed, 0.0)


## RigVMFunction_MathQuaternionToAxisAndAngle: [axis, signed angle in (-pi, pi]].
static func _to_axis_angle(q: Quaternion) -> Array:
	q = q.normalized()
	var s := Vector3(q.x, q.y, q.z)
	var axis := Vector3(1, 0, 0) if s.length_squared() < 1e-8 else s.normalized()
	var angle := 2.0 * acos(clampf(q.w, -1.0, 1.0))
	if nearly_zero_v(axis):
		return [Vector3(1, 0, 0), 0.0]
	var sign := -1.0 if angle < 0.0 else 1.0
	angle = absf(angle)
	if angle > TAU:
		angle = fmod(angle, TAU)
	if angle > PI:
		angle = TAU - angle
		sign = -sign
	return [axis, angle * sign]


# 4.22
func _alpha_linear_interp(value: float, speed: float, target: float) -> float:
	if speed <= 0.0 or absf(value - target) <= 0.001:
		return target
	return value + (target - value) * clampf(speed * _dt, 0.0, 1.0)


# 4.11
func _compute_pinned_toe(anim_g: Transform3D, pin_w: Transform3D) -> Transform3D:
	var anim_w := toW(anim_g)
	var a := axis_z(rq(anim_w))
	var b := axis_z(rq(pin_w))
	var q := from_two_vectors(Vector3(a.x, a.y, 0.0), Vector3(b.x, b.y, 0.0))
	return xf(q * rq(anim_w), Vector3(pin_w.origin.x, pin_w.origin.y, toWp(anim_g.origin).z))


# 4.18
func _pinned_toe_target(pin_w: Transform3D, pin_anim_w: Transform3D, anim_g: Transform3D, weight: float) -> Transform3D:
	var pinned_g := fromW(_compute_pinned_toe(anim_g, pin_w))
	var unlock := Transform3D(pinned_g.basis, fromWp((toW(anim_g).origin - pin_anim_w.origin) + pin_w.origin))
	var b := pinned_g if weight > 0.99 else unlock
	var e := cubic_ease_in_out(clampf(weight, 0.0, 1.0))
	return lerp_transform(anim_g, b, e)
	# ClampFootMinHeightToReferencePose is false.


# 4.15
func _adjust_position_to_plane(pos_flat: Vector3, height_offset: float, plane_point: Vector3, plane_normal: Vector3) -> Vector3:
	var slope_q := from_two_vectors(Vector3(0, 0, 1), axis_z(rq(G("animated_slope_angle_ctrl"))))
	var inv := slope_q.inverse()
	var normal := axis_z(inv * from_two_vectors(Vector3(0, 0, 1), plane_normal))   # QUIRK: If_1 hard-wired
	var point := plane_point if nearly_zero_v(plane_normal - Vector3(0, 0, 1), 0.01) else inv * plane_point
	var hit := intersect_plane(pos_flat, Vector3(0, 0, -1), point, normal)
	return hit + Vector3(0, 0, height_offset)


# 4.14
func _collide_position_with_plane(pos: Vector3, height_offset: float, plane_point: Vector3, plane_normal: Vector3) -> Array:
	var adj := _adjust_position_to_plane(pos, height_offset, plane_point, plane_normal)
	var hit := adj.z > pos.z
	return [adj if hit else pos, hit]


# 4.17
static func _slope_angle(plane_normal: Vector3, forward_axis: Vector3, up_axis: Vector3, rotation: Quaternion) -> float:
	var f := rotation * forward_axis
	var flat := unit(Vector3(f.x, f.y, 0.0))
	var dd := flat.dot(plane_normal)
	var deg := rad_to_deg(asin(dd)) if dd >= -1.0 and dd <= 1.0 else 0.0
	var u := rotation * up_axis
	return deg if u.z < 0.0 else -deg


# 4.3
func _update_leg_controls(k: int, floor_control: String, toe_null: String, toe_control: String, foot_bone: String,
		toe_bone: String, toe_forward_axis: Vector3, calc_null: String, calc_ctrl: String, foot_null: String,
		toe_up_axis: Vector3, animated_toe_ctrl: String) -> void:
	var animated_toe := G(animated_toe_ctrl)
	var plane_point := G(floor_control).origin
	var plane_normal := axis_z(rq(G(floor_control)))
	var foot_forward_axis: Vector3 = foot_to_toe_axis[k]
	# A
	setG(calc_null, _pinned_toe_target(pin_transform_world[k], pin_anim_transform_world[k], animated_toe, pin_weight[k]))
	# B
	var ct := G(calc_ctrl)
	setT(toe_null, _adjust_position_to_plane(ct.origin, ct.origin.z, plane_point, plane_normal))
	setR(toe_null, rq(G(calc_ctrl)))
	# C: Unreal M2 = G(foot) * inverse(G(toe)), M3 = M2 * G(toe ctrl), M4 = M2 * G(calc ctrl).
	var m2 := G(toe_bone).affine_inverse() * G(foot_bone)
	var m3 := G(toe_control) * m2
	setR(foot_null, rq(m3))
	var m4 := G(calc_ctrl) * m2
	if ALLOW_HEEL_LIFT:
		var heel_down := _adjust_position_to_plane(m3.origin, m4.origin.z, plane_point, plane_normal)
		var heel_up: Vector3 = _collide_position_with_plane(m3.origin, G(foot_bone).origin.z, plane_point, plane_normal)[0]
		var slope := _slope_angle(plane_normal, toe_forward_axis, toe_up_axis, rq(G(toe_control)))
		var tt := remap_clamped(slope, HEEL_UP_ANGLE_START, HEEL_UP_ANGLE_END, 0.0, 1.0)
		setT(foot_null, heel_down.lerp(heel_up, tt))
	else:
		setT(foot_null, _adjust_position_to_plane(m3.origin, m4.origin.z, plane_point, plane_normal))
	# D
	aim_item(foot_null, foot_forward_axis, G(toe_control).origin)


# 4.5
func _clamp_pelvis_offset(pelvis_position: Vector3, foot_bone: String, foot_control: String, leg_length: float, upper: String) -> Vector3:
	var adj := pelvis_position - G("pelvis").origin
	var upper_proposed := G(upper).origin + adj
	var foot_to_upper := upper_proposed - G(foot_control).origin
	var max_len := maxf(leg_length * HYPER_EXTENSION_LIMIT_FACTOR, rel(foot_bone, upper).origin.length())
	var clamped := clamp_length(foot_to_upper, 0.0, max_len)
	var upper_clamped := clamped + G(foot_control).origin
	return (pelvis_position - upper_proposed) + upper_clamped


# 4.9
func _update_pelvis_control() -> void:
	var pa := G("animated_pelvis_ctrl").origin
	var l := (pa - G("animated_toe_target_l_ctrl").origin) + G("toe_l_ctrl").origin
	var r := (pa - G("animated_toe_target_r_ctrl").origin) + G("toe_r_ctrl").origin
	var m := l.lerp(r, 0.5)
	var p0 := Vector3(m.x, m.y, maxf(l.z, r.z))
	var p1 := _clamp_pelvis_offset(p0, "foot_l", "foot_l_ctrl", left_leg_length, "thigh_l")
	var p2 := _clamp_pelvis_offset(p1, "foot_r", "foot_r_ctrl", right_leg_length, "thigh_r")
	pelvis_offset = damp_vector(pelvis_offset, p2 - G("pelvis").origin, PELVIS_SMOOTHING_TIME)
	setT("pelvis_null", G("pelvis").origin + pelvis_offset)
	setR("pelvis_null", rq(G("pelvis")))


# 4.4
func _solve_leg_ik(upper: String, lower: String, foot_bone: String, foot_control: String, primary: Vector3,
		secondary: Vector3, leg_length: float, toe_control: String, clamped_null: String, clamped_ctrl: String,
		clamped_toe_null: String, foot_to_toe: Vector3) -> void:
	# B
	var r1 := rel(foot_control, upper)
	var r0 := rel(foot_bone, upper)
	var max_len := maxf(r0.origin.length(), leg_length * HYPER_EXTENSION_LIMIT_FACTOR) + 0.1
	if r1.origin.length_squared() > max_len * max_len:
		var v := Transform3D(r1.basis, clamp_length(r1.origin, 0.0, max_len))
		setG(clamped_null, G(upper) * v)
	else:
		setG(clamped_null, G(foot_control))
	# C: Weight 0 in the asset (QUIRK): nothing.
	# D
	setG(clamped_toe_null, G(toe_control))
	aim_item(clamped_null, foot_to_toe, G(toe_control).origin)
	# E
	var pole := (G(foot_control).origin - G(upper).origin).cross(rq(G(lower)) * secondary.cross(primary)) + G(upper).origin
	_two_bone_ik_simple(upper, lower, foot_bone, G(clamped_ctrl), primary, secondary, pole)


# 5.4 TwoBoneIKSimplePerItem (no stretch, secondary weight 1, weight 1).
func _two_bone_ik_simple(a_name: String, b_name: String, eff_name: String, effector: Transform3D, primary: Vector3,
		secondary: Vector3, pole: Vector3) -> void:
	var ta := G(a_name)
	var tb := Transform3D(ta.basis, G(b_name).origin)
	var tc := effector
	var len_a := GI(a_name).origin.distance_to(GI(b_name).origin)
	var len_b := GI(b_name).origin.distance_to(GI(eff_name).origin)
	var root := ta.origin
	var sol := _solve_two_bone(root, tb.origin, tc.origin, pole, len_a, len_b)
	tb.origin = sol[0]
	tc.origin = sol[1]
	var ra := rq(ta)
	var rb := rq(tb)
	var axis := ra * primary
	var t1 := tb.origin - ta.origin
	var bone_b_loc := tb.origin
	var fully_extended := false
	if not nearly_zero_v(t1) and not nearly_zero_v(axis):
		t1 = safe_normal(t1)
		fully_extended = absf(safe_normal(tc.origin - root).dot(t1) - 1.0) < 1e-4
		ra = (LEG_IK.find_between(axis, t1) * ra).normalized()
		axis = ra * secondary
		var t2 := (pole - root) if fully_extended else (bone_b_loc - (tc.origin + ta.origin) * 0.5)
		if not nearly_zero_v(t2) and not nearly_zero_v(axis):
			t2 = safe_normal(t2 - t2.dot(t1) * t1)
			ra = (LEG_IK.find_between(axis, t2) * ra).normalized()
	# TB's rotation starts as TA's original rotation.
	axis = rb * primary
	t1 = tc.origin - bone_b_loc
	if not nearly_zero_v(t1) and not nearly_zero_v(axis):
		t1 = safe_normal(t1)
		rb = (LEG_IK.find_between(axis, t1) * rb).normalized()
		axis = rb * secondary
		var t2 := (pole - bone_b_loc) if fully_extended else (bone_b_loc - (tc.origin + ta.origin) * 0.5)
		if not nearly_zero_v(t2) and not nearly_zero_v(axis):
			t2 = safe_normal(t2 - t2.dot(t1) * t1)
			rb = (LEG_IK.find_between(axis, t2) * rb).normalized()
	_set_global(_id[a_name], xf(ra, ta.origin))
	_set_global(_id[b_name], xf(rb, tb.origin))
	_set_global(_id[eff_name], xf(rq(tc), tc.origin))


## AnimationCore::SolveTwoBoneIK with explicit lengths, no stretch: [joint, end].
static func _solve_two_bone(root: Vector3, joint: Vector3, effector: Vector3, joint_target: Vector3, la: float, lb: float) -> Array:
	var d := effector - root
	var l := d.length()
	var max_l := la + lb
	var dir: Vector3
	if l < 1e-4:
		l = 1e-4
		dir = Vector3(1, 0, 0)
	else:
		dir = safe_normal(d)
	var jt := joint_target - root
	var bend: Vector3
	if jt.length_squared() < 1e-8:
		bend = Vector3(0, 1, 0)
	else:
		var plane_n := dir.cross(jt)
		if plane_n.length_squared() < 1e-8:
			# FVector::FindBestAxisVectors
			var nx := absf(dir.x); var ny := absf(dir.y); var nz := absf(dir.z)
			var a1 := Vector3(1, 0, 0) if (nz > nx and nz > ny) else Vector3(0, 0, 1)
			a1 = (a1 - dir * a1.dot(dir)).normalized()
			bend = a1.cross(dir)
		else:
			bend = safe_normal(jt - jt.dot(dir) * dir)
	if l >= max_l:
		return [root + la * dir, root + max_l * dir]
	var cos_a := (la * la + l * l - lb * lb) / (2.0 * la * l) if absf(2.0 * la * l) > 0.0 else 0.0
	var reverse := cos_a < 0.0
	var ang := acos(clampf(cos_a, -1.0, 1.0))
	var h := la * sin(ang)
	var p2 := la * la - h * h
	var p := sqrt(p2) if p2 > 0.0 else 0.0
	if reverse:
		p = -p
	return [root + p * dir + h * bend, effector]


# 4.16
func _update_foot_post_solve(foot_bone: String, toe_bone: String, floor_control: String, calc_ctrl: String,
		toe_forward_axis: Vector3, foot_to_toe: Vector3) -> void:
	var floor_point := G(floor_control).origin
	var floor_normal := axis_z(rq(G(floor_control)))
	var min_toe_height := minf(GI(toe_bone).origin.z, G(calc_ctrl).origin.z)
	# B
	var toe_bottom := G(toe_bone).origin - Vector3(0, 0, min_toe_height)
	if (toe_bottom - floor_point).dot(floor_normal) < -0.01:
		var cp := closest_on_plane(toe_bottom, floor_point, floor_normal) + Vector3(0, 0, min_toe_height)
		var foot := G(foot_bone).origin
		var a := cp - foot
		var d1 := a.dot(floor_normal)
		var along_n := floor_normal * d1
		var l2 := relI(toe_bone, foot_bone).origin.length_squared()
		var bb := l2 - d1 * d1
		var b := sqrt(bb) if bb >= 0.0 else 0.0
		var ft := G(toe_bone).origin - foot
		var d2 := ft.dot(floor_normal)
		var perp := unit(ft - floor_normal * d2)
		var target := (perp * b + along_n) + foot
		aim_item(foot_bone, foot_to_toe, target)
	# C
	var tip := G(toe_bone) * (toe_forward_axis * TOE_LENGTH)
	var tip_anim := G(calc_ctrl) * (toe_forward_axis * TOE_LENGTH)
	var r := _collide_position_with_plane(tip, minf(tip_anim.z, min_toe_height), floor_point, floor_normal)
	if r[1]:
		aim_item(toe_bone, toe_forward_axis, r[0])


# ------------------------------------------------------------------ BasicIK (LegIK onto ik_foot)

func _basic_ik() -> void:
	for k in 2:
		var s := "_l" if k == 0 else "_r"
		var ids := [_id["foot" + s], _id["calf" + s], _id["thigh" + s]]
		var leg := [_g[ids[0]], _g[ids[1]], _g[ids[2]]]
		var ball_local := _g[ids[0]].affine_inverse() * G("ball" + s)
		(_legs_basic[k] as RefCounted).solve(leg, G("ik_foot" + s))
		_g[ids[2]] = leg[2]
		_g[ids[1]] = leg[1]
		_g[ids[0]] = leg[0]
		_g[_id["ball" + s]] = leg[0] * ball_local
