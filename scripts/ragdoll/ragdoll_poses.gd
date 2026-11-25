# The ragdoll target pose: the sample's ABP "Ragdoll" state machine,
# evaluated directly from the clips for the 23 body bones. It outputs the local bone rotations the
# muscles pull toward and the four Ragdoll_Strength curves (head, torso, arms, legs).
#
#   entry (0.2 s from the pre-ragdoll pose) -> conduit: TimeToImpact > 0.3 -> In Air, else On Ground
#   In Air -> On Ground   TimeToImpact <= 0.2           1.0 s, Ragdoll_Fall_to_Ground_BlendCurve
#   On Ground -> In Air   in state > 0.5 s and TTI > 0.5  0.5 s
#   In Air:    TTI <= 0.5 ? BS_Ragdoll_Reach (rate 1.5, no loop, restarts; blend 0.2 s; curves 1/1/1.5/0.2)
#                         : BS_Ragdoll_Flail (loop; blend 0.75 s; curves 1/1/1/1)
#   On Ground: lerp(injury pose, BS_Ragdoll_Rolling_Poses (curves 1/1/2/1), RollAmount interpolated 5/s up, 1/s down)
#              injury None = BS_Ragdoll_OnGround_Poses (curves 1/1/1/0.2), others = M_ragdoll_poses_injured frames
# Blend spaces: X = impact yaw, Y = impact pitch (degrees); weights by Delaunay triangulation of the
# samples (Unreal interpolates a triangulated grid), smoothed per sample at the asset's
# TargetWeightInterpolationSpeedPerSec.
extends RefCounted

const DATA := "res://extracted/data/"
const ANIMS := "res://extracted/anims/"
const FPS := 30.0

enum State { AIR, GROUND }
enum Injury { NONE, HEAD_FACE, HEAD_BACK, STUNNED, BODY_FRONT, LIMP, GROIN }

const INJURY_POSES := {  # time in M_ragdoll_poses_injured, curves head/torso/arms/legs
	Injury.HEAD_FACE: [0.08, Vector4(1, 0.5, 1, 0.3)],
	Injury.HEAD_BACK: [0.15, Vector4(1, 0.5, 2, 0.1)],
	Injury.BODY_FRONT: [0.21, Vector4(1, 1, 2, 0.2)],
	Injury.LIMP: [0.36, Vector4(0.3, 0.3, 0.3, 0.3)],
	Injury.GROIN: [0.29, Vector4(2, 2, 2, 0.2)],
	Injury.STUNNED: [0.0, Vector4(0.2, 1, 1, 1)],
}
const REACH_CURVES := Vector4(1, 1, 1.5, 0.2)
const FLAIL_CURVES := Vector4(1, 1, 1, 1)
const ROLLING_CURVES := Vector4(1, 1, 2, 1)
const ON_GROUND_CURVES := Vector4(1, 1, 1, 0.2)


class BlendSpace:
	var samples: Array = []     # [Vector2 position, clip key, single frame (-1 = play), rate scale]
	var one_d := false
	var tris := PackedInt32Array()
	var speed := 4.0
	var loop := true
	var weights := PackedFloat32Array()
	var phase := 0.0            # normalized time
	var started := false


var bones: PackedStringArray
var rest: Array[Quaternion] = []
var _clips := {}               # clip key -> [Animation, PackedInt32Array rotation track per bone, rate scale]
var flail: BlendSpace
var reach: BlendSpace
var on_ground: BlendSpace
var rolling: BlendSpace

# State machine.
var injury := Injury.NONE
var state := State.AIR
var state_time := 0.0
## Blend layers bottom to top: [state (-1 = pre-ragdoll pose), weight, blend time, curve].
var _layers: Array = []
var _pre_pose: Array = []
var _reach_w := 0.0
var _reach_active := false
var _roll_alpha := 0.0
var curves := Vector4.ONE


func _init(body_bones: PackedStringArray, skeleton: Skeleton3D) -> void:
	bones = body_bones
	for b in bones:
		rest.append(skeleton.get_bone_rest(skeleton.find_bone(b)).basis.get_rotation_quaternion())
	var bs: Dictionary = JSON.parse_string(FileAccess.get_file_as_string(DATA + "blendspaces.json"))
	var seqs: Dictionary = JSON.parse_string(FileAccess.get_file_as_string(DATA + "sequences.json"))
	flail = _blend_space(bs["Ragdoll/BS_Ragdoll_Flail"], seqs)
	reach = _blend_space(bs["Ragdoll/BS_Ragdoll_Reach"], seqs)
	reach.loop = false  # the In Air node plays it once (bLoop false on the player node)
	on_ground = _blend_space(bs["Ragdoll/BS_Ragdoll_OnGround_Poses"], seqs, true)
	rolling = _blend_space(bs["Ragdoll/BS_Ragdoll_Rolling_Poses"], seqs, true)
	_clip("Ragdoll/M_ragdoll_poses_injured", seqs)


func _blend_space(def: Dictionary, seqs: Dictionary, one_d := false) -> BlendSpace:
	var b := BlendSpace.new()
	b.speed = float(def.get("TargetWeightInterpolationSpeedPerSec", 0.0))
	b.loop = bool(def.get("bLoop", true))
	b.one_d = one_d
	var points := PackedVector2Array()
	for s: Dictionary in def["samples"]:
		var key: String = s["asset"]
		_clip(key, seqs)
		var frame := int(s.get("FrameIndexToSample", 0)) if s.get("bUseSingleFrameForBlending", false) else -1
		var pos := Vector2(float(s["position"][0]), 0.0 if one_d else float(s["position"][1]))
		b.samples.append([pos, key, frame, float(s.get("RateScale", 1.0))])
		points.append(pos)
	if not one_d:
		b.tris = Geometry2D.triangulate_delaunay(points)
	b.weights.resize(b.samples.size())
	return b


func _clip(key: String, seqs: Dictionary) -> void:
	if _clips.has(key):
		return
	var lib: AnimationLibrary = load(ANIMS + key + ".fbx")
	var anim := lib.get_animation(lib.get_animation_list()[0])
	var tracks := PackedInt32Array()
	for b in bones:
		tracks.append(anim.find_track(NodePath("Skeleton3D:" + b), Animation.TYPE_ROTATION_3D))
	_clips[key] = [anim, tracks, float(seqs.get(key, {}).get("RateScale", 1.0))]


## Local rotations of the body bones in a clip at a time.
func _clip_pose(key: String, t: float) -> Array:
	var c: Array = _clips[key]
	var anim: Animation = c[0]
	var tracks: PackedInt32Array = c[1]
	t = clampf(t, 0.0, anim.length)
	var out := []
	for i in bones.size():
		out.append(anim.rotation_track_interpolate(tracks[i], t) if tracks[i] >= 0 else rest[i])
	return out


static func _blend(poses: Array, weights: Array) -> Array:
	var out := []
	var n: int = (poses[0] as Array).size()
	for i in n:
		var acc := Quaternion(0, 0, 0, 0)
		var ref: Quaternion = poses[0][i]
		for k in poses.size():
			var w: float = weights[k]
			if w <= 0.0:
				continue
			var q: Quaternion = poses[k][i]
			if q.dot(ref) < 0.0:
				q = -q
			acc = Quaternion(acc.x + q.x * w, acc.y + q.y * w, acc.z + q.z * w, acc.w + q.w * w)
		out.append(acc.normalized() if acc.length_squared() > 1e-12 else ref)
	return out


static func _lerp_pose(a: Array, b: Array, t: float) -> Array:
	if t <= 0.0:
		return a
	if t >= 1.0:
		return b
	var out := []
	for i in a.size():
		out.append((a[i] as Quaternion).slerp(b[i], t))
	return out


# ------------------------------------------------------------------ blend space weights

func _target_weights(b: BlendSpace, p: Vector2) -> PackedFloat32Array:
	var w := PackedFloat32Array()
	w.resize(b.samples.size())
	if b.one_d:
		var best_lo := -1
		var best_hi := -1
		for i in b.samples.size():
			var x: float = b.samples[i][0].x
			if x <= p.x and (best_lo < 0 or x > b.samples[best_lo][0].x):
				best_lo = i
			if x >= p.x and (best_hi < 0 or x < b.samples[best_hi][0].x):
				best_hi = i
		if best_lo < 0:
			best_lo = best_hi
		if best_hi < 0:
			best_hi = best_lo
		var xa: float = b.samples[best_lo][0].x
		var xb: float = b.samples[best_hi][0].x
		var t := 0.0 if is_equal_approx(xa, xb) else (p.x - xa) / (xb - xa)
		w[best_lo] += 1.0 - t
		w[best_hi] += t
		return w
	for k in range(0, b.tris.size(), 3):
		var a: Vector2 = b.samples[b.tris[k]][0]
		var c: Vector2 = b.samples[b.tris[k + 1]][0]
		var d: Vector2 = b.samples[b.tris[k + 2]][0]
		var den := (c.y - d.y) * (a.x - d.x) + (d.x - c.x) * (a.y - d.y)
		if absf(den) < 1e-9:
			continue
		var l0 := ((c.y - d.y) * (p.x - d.x) + (d.x - c.x) * (p.y - d.y)) / den
		var l1 := ((d.y - a.y) * (p.x - d.x) + (a.x - d.x) * (p.y - d.y)) / den
		var l2 := 1.0 - l0 - l1
		if l0 >= -1e-4 and l1 >= -1e-4 and l2 >= -1e-4:
			w[b.tris[k]] += maxf(l0, 0.0)
			w[b.tris[k + 1]] += maxf(l1, 0.0)
			w[b.tris[k + 2]] += maxf(l2, 0.0)
			return w
	# Outside the hull: nearest sample.
	var best := 0
	for i in b.samples.size():
		if (b.samples[i][0] as Vector2).distance_to(p) < (b.samples[best][0] as Vector2).distance_to(p):
			best = i
	w[best] = 1.0
	return w


func _evaluate(b: BlendSpace, p: Vector2, dt: float, play_rate := 1.0) -> Array:
	p = Vector2(clampf(p.x, -180.0, 180.0), clampf(p.y, -90.0, 90.0))
	var target := _target_weights(b, p)
	if not b.started:
		b.weights = target
		b.started = true
		b.phase = 0.0
	elif b.speed > 0.0:
		var total := 0.0
		for i in b.weights.size():
			b.weights[i] = move_toward(b.weights[i], target[i], b.speed * dt)
			total += b.weights[i]
		if total > 1e-6:
			for i in b.weights.size():
				b.weights[i] /= total
	else:
		b.weights = target
	# Normalized time shared by every sample (blend space sync), length weighted by the samples.
	var length := 0.0
	for i in b.samples.size():
		var s: Array = b.samples[i]
		if s[2] < 0:
			var c: Array = _clips[s[1]]
			length += b.weights[i] * (c[0] as Animation).length / maxf(float(s[3]) * float(c[2]), 1e-3)
	if length > 1e-4:
		b.phase += dt * play_rate / length
		b.phase = fposmod(b.phase, 1.0) if b.loop else minf(b.phase, 1.0)
	var poses := []
	var ws := []
	for i in b.samples.size():
		if b.weights[i] <= 1e-4:
			continue
		var s: Array = b.samples[i]
		var anim: Animation = (_clips[s[1]] as Array)[0]
		var t: float = float(s[2]) / FPS if s[2] >= 0 else b.phase * anim.length
		poses.append(_clip_pose(s[1], t))
		ws.append(b.weights[i])
	if poses.is_empty():
		return rest.duplicate()
	return _blend(poses, ws)


# ------------------------------------------------------------------ state machine

## Starts a ragdoll from the animated local rotations of the body bones.
func reset(pre_pose: Array, time_to_impact: float, injury_state: int) -> void:
	injury = injury_state
	_pre_pose = pre_pose
	for b in [flail, reach, on_ground, rolling]:
		b.started = false
	_reach_active = false
	_reach_w = 0.0
	_roll_alpha = 0.0
	state = State.AIR if time_to_impact > 0.3 and injury == Injury.NONE else State.GROUND
	state_time = 0.0
	# Outer state machine: NoRagdoll -> In Ragdoll, inertialization 0.2 s (as a crossfade here).
	_layers = [[-1, 1.0, 0.0, 0], [state, 0.0, 0.2, 0]]


## One tick: returns the target local rotations (one per body bone); `curves` holds the strengths.
func update(dt: float, time_to_impact: float, impact_dir: Vector2, roll_amount: float) -> Array:
	state_time += dt
	# Inner transitions (one per frame).
	if state == State.AIR and time_to_impact <= 0.2:
		_go(State.GROUND, 1.0, 1)
	elif state == State.GROUND and state_time > 0.5 and time_to_impact > 0.5 and injury == Injury.NONE:
		_go(State.AIR, 0.5, 0)
	# Advance the layer weights; a layer at full weight hides everything under it.
	for k in range(1, _layers.size()):
		var l: Array = _layers[k]
		l[1] = 1.0 if l[2] <= 0.0 else minf(1.0, l[1] + dt / l[2])
	for k in range(_layers.size() - 1, 0, -1):
		if _curve(_layers[k][3], _layers[k][1]) >= 1.0:
			_layers = _layers.slice(k)
			break
	var evaluated := {}
	var pose: Array = []
	var curve_acc := Vector4.ZERO
	var curve_w := 0.0
	for k in _layers.size():
		var l: Array = _layers[k]
		var layer_pose: Array
		var layer_curves := Vector4.ZERO
		if l[0] < 0:
			layer_pose = _pre_pose
		else:
			if not evaluated.has(l[0]):
				evaluated[l[0]] = _state_pose(l[0], dt, time_to_impact, impact_dir, roll_amount)
			layer_pose = evaluated[l[0]][0]
			layer_curves = evaluated[l[0]][1]
		var a := 1.0 if k == 0 else _curve(l[3], l[1])
		pose = layer_pose if k == 0 else _lerp_pose(pose, layer_pose, a)
		if l[0] >= 0:
			# The strength curves are filtered out of the blend (DeadBlending FilteredCurves): no
			# contribution from the pre-ragdoll pose.
			curve_acc = curve_acc * (1.0 - a) + layer_curves * a if curve_w > 0.0 else layer_curves
			curve_w = 1.0
	curves = curve_acc
	return pose


func _go(to: int, blend_time: float, curve: int) -> void:
	state = to
	state_time = 0.0
	if to == State.AIR:
		reach.started = false
		flail.started = false
		_reach_active = false
		_reach_w = 0.0
	else:
		on_ground.started = false
		rolling.started = false
		_roll_alpha = 0.0
	_layers.append([to, 0.0, blend_time, curve])


# 0 = HermiteCubic (state machine default), 1 = Ragdoll_Fall_to_Ground_BlendCurve.
static func _curve(kind: int, t: float) -> float:
	t = clampf(t, 0.0, 1.0)
	if kind == 1:
		# Keys (0, 0) (0.2, 0 flat) (1.0, 1): zero until 0.2, then an ease to 1.
		if t <= 0.2:
			return 0.0
		var u := (t - 0.2) / 0.8
		return u * u * (3.0 - 2.0 * u)
	return t * t * (3.0 - 2.0 * t)


func _state_pose(s: int, dt: float, tti: float, dir: Vector2, roll_amount: float) -> Array:
	if s == State.AIR:
		var want := tti <= 0.5
		if want and not _reach_active:
			reach.started = false  # ResetChildOnActivate
		_reach_active = want
		_reach_w = move_toward(_reach_w, 1.0 if want else 0.0, dt / (0.2 if want else 0.75))
		var poses := []
		var ws := []
		var c := Vector4.ZERO
		if _reach_w > 0.0:
			poses.append(_evaluate(reach, dir, dt, 1.5))
			ws.append(_reach_w)
			c += REACH_CURVES * _reach_w
		if _reach_w < 1.0:
			poses.append(_evaluate(flail, dir, dt))
			ws.append(1.0 - _reach_w)
			c += FLAIL_CURVES * (1.0 - _reach_w)
		return [_lerp_pose(poses[0], poses[1], ws[1]) if poses.size() == 2 else poses[0], c]
	# On Ground.
	var speed := 5.0 if roll_amount > _roll_alpha else 1.0
	_roll_alpha += (roll_amount - _roll_alpha) * clampf(dt * speed, 0.0, 1.0)
	var a_pose: Array
	var a_curves: Vector4
	if injury == Injury.NONE:
		a_pose = _evaluate(on_ground, dir, dt)
		a_curves = ON_GROUND_CURVES
	else:
		var entry: Array = INJURY_POSES[injury]
		a_pose = _clip_pose("Ragdoll/M_ragdoll_poses_injured", entry[0])
		a_curves = entry[1]
	if _roll_alpha <= 1e-3:
		return [a_pose, a_curves]
	var b_pose := _evaluate(rolling, dir, dt)
	return [_lerp_pose(a_pose, b_pose, _roll_alpha), a_curves.lerp(ROLLING_CURVES, _roll_alpha)]
