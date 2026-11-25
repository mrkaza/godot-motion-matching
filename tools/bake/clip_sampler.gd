# Samples bone transforms of one clip at any time, the way Unreal's pose search indexer does
# (PoseSearchAssetSampler.cpp): the pose loops or clamps, and the root keeps moving past either end.
# Transforms are skeleton space and include the root track (root motion stays in the root bone).
class_name ClipSampler
extends RefCounted

const EXTRAPOLATION_STEP := 1.0 / 30.0  # Unreal's ExtrapolationSampleTime

var anim: Animation
var length: float
var loops: bool
var curves: Dictionary  # name -> [times, values]

var _parents: PackedInt32Array
var _rests: Array[Transform3D]
var _pos_track: PackedInt32Array
var _rot_track: PackedInt32Array
var _scale_track: PackedInt32Array
var _root: int
var _memo := {}


func _init(animation: Animation, skeleton: Skeleton3D, clip_loops: bool, clip_curves: Array) -> void:
	anim = animation
	length = animation.length
	loops = clip_loops
	_root = skeleton.find_bone("root")
	var n := skeleton.get_bone_count()
	_parents.resize(n)
	_pos_track.resize(n)
	_rot_track.resize(n)
	_scale_track.resize(n)
	for b in n:
		_parents[b] = skeleton.get_bone_parent(b)
		_rests.append(skeleton.get_bone_rest(b))
		_pos_track[b] = -1
		_rot_track[b] = -1
		_scale_track[b] = -1
	for t in anim.get_track_count():
		var bone := skeleton.find_bone(anim.track_get_path(t).get_concatenated_subnames())
		if bone < 0:
			continue
		match anim.track_get_type(t):
			Animation.TYPE_POSITION_3D: _pos_track[bone] = t
			Animation.TYPE_ROTATION_3D: _rot_track[bone] = t
			Animation.TYPE_SCALE_3D: _scale_track[bone] = t
	for c: Dictionary in clip_curves:
		curves[c["name"]] = [PackedFloat32Array(c["times"]), PackedFloat32Array(c["values"])]


## Skeleton-space transform of a bone at any time.
func bone(b: int, t: float) -> Transform3D:
	if t >= 0.0 and t <= length:
		return _raw(b, t)
	if loops and length > 0.0:
		var k := floori(t / length)
		var tm := t - k * length
		var cycle := _raw(_root, length) * _raw(_root, 0.0).affine_inverse()
		return _power(cycle, k) * _raw(b, tm)
	var c := clampf(t, 0.0, length)
	var root_c := _raw(_root, c)
	var root_t := _extrapolated_root(t)
	return root_t * root_c.affine_inverse() * _raw(b, c)


## Curve value at a time (linear between keys, held outside them). 0 when the clip has no such curve.
func curve(name: String, t: float) -> float:
	if not curves.has(name):
		return 0.0
	var times: PackedFloat32Array = curves[name][0]
	var vals: PackedFloat32Array = curves[name][1]
	if times.is_empty():
		return 0.0
	if loops and length > 0.0:
		t = fposmod(t, length)
	else:
		t = clampf(t, 0.0, length)
	var i := times.bsearch(t)
	if i <= 0:
		return vals[0]
	if i >= times.size():
		return vals[-1]
	var a := (t - times[i - 1]) / maxf(times[i] - times[i - 1], 1e-9)
	return lerpf(vals[i - 1], vals[i], a)


## Root past the clip's ends: whole steps of the first or last 1/30 s of root motion, and the
## fractional rest blended from identity (ExtrapolateRootMotion, PoseSearchAssetSampler.cpp:19-52).
func _extrapolated_root(t: float) -> Transform3D:
	if t > length:
		var r_end := _raw(_root, length)
		var delta := _raw(_root, maxf(length - EXTRAPOLATION_STEP, 0.0)).affine_inverse() * r_end
		return r_end * _steps(delta, (t - length) / EXTRAPOLATION_STEP)
	var r_start := _raw(_root, 0.0)
	var delta0 := r_start.affine_inverse() * _raw(_root, minf(EXTRAPOLATION_STEP, length))
	return r_start * _steps(delta0.affine_inverse(), -t / EXTRAPOLATION_STEP)


static func _steps(delta: Transform3D, count: float) -> Transform3D:
	var whole := floori(count)
	var result := _power(delta, whole)
	var frac := count - whole
	if frac > 0.0:
		var part := Transform3D(Basis(Quaternion.IDENTITY.slerp(delta.basis.get_rotation_quaternion(), frac)), delta.origin * frac)
		result = result * part
	return result


static func _power(xf: Transform3D, k: int) -> Transform3D:
	var base := xf if k >= 0 else xf.affine_inverse()
	var result := Transform3D.IDENTITY
	for i in absi(k):
		result = base * result
	return result


func _raw(b: int, t: float) -> Transform3D:
	var key := Vector2i(b, roundi(t * 100000.0))
	if _memo.has(key):
		return _memo[key]
	var local := _rests[b]
	var origin := local.origin if _pos_track[b] < 0 else anim.position_track_interpolate(_pos_track[b], t)
	var rot := local.basis.get_rotation_quaternion() if _rot_track[b] < 0 else anim.rotation_track_interpolate(_rot_track[b], t)
	var scl := local.basis.get_scale() if _scale_track[b] < 0 else anim.scale_track_interpolate(_scale_track[b], t)
	local = Transform3D(Basis(rot) * Basis.from_scale(scl), origin)
	var result := local if _parents[b] < 0 else _raw(_parents[b], t) * local
	_memo[key] = result
	return result
