# Puts the clips, made on the sample's UEFN mannequin, on Manny the way the sample does: BP_Manny is
# SKM_Manny_Simple with ABP_GenericRetarget, a Retarget Pose From Mesh running RTG_UEFN_to_UE5_Mannequin.
# This runs that retargeter's op stack (UE 5.8 IKRig: PelvisMotionOp.cpp, FKChainsOp.cpp,
# BlendToSourceOp.cpp, RunIKRigOp.cpp, AlignPoleVectorOp.cpp) with its settings and both reference poses
# from extracted/data/retarget.json (tools/unreal/export_retarget.py). The stack's Offset Goals and Speed
# Plant ops do nothing with the sample's settings (zero offsets, no speed curves) and are left out. The IK
# Rig's full-body solve (pelvis pinned, knees and elbows hinged about their Z) is a two-bone solve per limb.
#
# The skeleton's animated pose (after the physics bodies) is read as the UEFN mannequin's pose: its joint
# rotations on the UEFN bone offsets. The result is written over it, so everything after this modifier
# (foot lock) and the mesh see Manny. Code that measures the clips (motion_matcher.gd, traversal) reads
# the pose before modifiers and the clip skeleton (source_pose()).
extends SkeletonModifier3D

const DATA := "res://extracted/data/retarget.json"
const CM := 0.01
const IK_CHAINS := ["LeftLeg", "RightLeg", "LeftArm", "RightArm"]

## ABP_GenericRetarget's UpdateRetargetProfile: per chain, the value of its curve in the curve map
## (0..1), which blends the chain's Blend to Source from the asset's value to 1. Set each frame by the
## motion matcher from the playing clips.
var chain_curves := {}

static var _data: Dictionary

var _n := 0
var _t_parent: PackedInt32Array
var _t_order: PackedInt32Array
var _t_rp_local: Array[Transform3D] = []
var _t_rp_global: Array[Transform3D] = []
var _s_names: PackedStringArray
var _s_parent: PackedInt32Array
var _s_from_t: PackedInt32Array      # source bone -> Manny bone of the same name (-1 if none)
var _s_animated_pos: Array[bool] = []
var _s_rp_local: Array[Transform3D] = []
var _s_rp_global: Array[Transform3D] = []
var _t_pelvis := -1
var _s_pelvis := -1
var _pelvis_scale := 1.0
var _pelvis_offset := Vector3.ZERO
var _fk: Array[Dictionary] = []
var _fk_of_bone: PackedInt32Array    # Manny bone -> index in _fk, or -1
var _ik: Array[Dictionary] = []
var _S: Array[Transform3D] = []
var _T: Array[Transform3D] = []


static func data() -> Dictionary:
	if _data.is_empty():
		_data = JSON.parse_string(FileAccess.get_file_as_string(DATA))
	return _data


## Unreal component space (cm, left-handed) to the skeleton's space in Godot as the FBX import gives it
## (metres, Y mirrored).
static func ue_vec(a: Array) -> Vector3:
	return Vector3(a[0], -a[1], a[2]) * CM


static func ue_quat(a: Array) -> Quaternion:
	return Quaternion(-a[0], a[1], -a[2], a[3]).normalized()


static func ue_xform(e: Dictionary) -> Transform3D:
	return Transform3D(Basis(ue_quat(e["q"])), ue_vec(e["t"]))


func setup(skeleton: Skeleton3D) -> void:
	name = "Retarget"
	skeleton.add_child(self)
	var d := data()
	_n = skeleton.get_bone_count()
	_t_parent.resize(_n)
	for b in _n:
		_t_parent[b] = skeleton.get_bone_parent(b)
	_t_order = _order(_t_parent)
	# Target retarget pose: Manny's reference pose, the pelvis moved by RootTranslationOffset (global), then
	# each bone's rotation offset applied in its own frame (FResolvedRetargetPoseSet::AddOrUpdateRetargetPose).
	var t_ref: Dictionary = d["target_ref"]
	for b in _n:
		var bn := skeleton.get_bone_name(b)
		_t_rp_local.append(ue_xform(t_ref[bn]) if t_ref.has(bn) else skeleton.get_bone_rest(b))
	_t_pelvis = skeleton.find_bone(d["target_ikrig"]["pelvis"])
	_t_rp_global = _globals(_t_rp_local, _t_parent, _t_order)
	var tp: Dictionary = d["target_pose"]
	var pelvis_g := _t_rp_global[_t_pelvis]
	pelvis_g.origin += ue_vec(tp["root_offset"])
	_t_rp_local[_t_pelvis] = _parent_of(_t_rp_global, _t_parent, _t_pelvis).affine_inverse() * pelvis_g
	for bn: String in tp["rotations"]:
		var b := skeleton.find_bone(bn)
		if b >= 0:
			var l := _t_rp_local[b]
			_t_rp_local[b] = Transform3D(Basis(l.basis.get_rotation_quaternion() * ue_quat(tp["rotations"][bn])), l.origin)
	_t_rp_global = _globals(_t_rp_local, _t_parent, _t_order)
	# Source: the UEFN mannequin's hierarchy and reference pose (no source retarget pose in the asset).
	var cs := Mannequin.clip_skeleton()
	var s_ref: Dictionary = d["source_ref"]
	var sn := cs.get_bone_count()
	_s_parent.resize(sn)
	_s_from_t.resize(sn)
	for b in sn:
		var bn := cs.get_bone_name(b)
		_s_names.append(bn)
		_s_parent[b] = cs.get_bone_parent(b)
		_s_from_t[b] = skeleton.find_bone(bn)
		_s_animated_pos.append(bn in Mannequin.POSITION_BONES)
		_s_rp_local.append(ue_xform(s_ref[bn]) if s_ref.has(bn) else cs.get_bone_rest(b))
	var s_order := _order(_s_parent)
	_s_rp_global = _globals(_s_rp_local, _s_parent, s_order)
	_s_pelvis = cs.find_bone(d["source_ikrig"]["pelvis"])
	# Pelvis Motion: motion scaled by the pelvis height ratio (InitializeTarget).
	var pel: Dictionary = d["ops"]["pelvis"]
	_pelvis_scale = _t_rp_global[_t_pelvis].origin.z / _s_rp_global[_s_pelvis].origin.z
	_pelvis_offset = ue_vec(pel["translation_offset_global"])
	# FK chains, in the op's order.
	_fk_of_bone.resize(_n)
	_fk_of_bone.fill(-1)
	var chain_map: Dictionary = d["ops"]["chain_map"]
	for c: Dictionary in d["ops"]["fk_chains"]:
		var t_chain := _chain(d["target_ikrig"]["chains"], c["target"], skeleton.find_bone, _t_parent)
		var s_chain := _chain(d["source_ikrig"]["chains"], _lookup(chain_map, c["target"]), cs.find_bone, _s_parent)
		if t_chain.is_empty() or s_chain.is_empty():
			continue
		var fk := {"t": t_chain, "s": s_chain, "rotation": c["rotation_mode"], "translation": c["translation_mode"],
			"t_params": _params(_t_rp_global, t_chain), "s_params": _params(_s_rp_global, s_chain),
			"t_cp": _t_parent[t_chain[0]], "s_cp": _s_parent[s_chain[0]]}
		for b: int in t_chain:
			_fk_of_bone[b] = _fk.size()
		_fk.append(fk)
	# IK goals: Run IK Rig, Blend to Source, Pole Vector Alignment.
	var bts: Dictionary = d["ops"]["blend_to_source"]
	var align: Dictionary = d["ops"]["align_pole"]
	for cn: String in IK_CHAINS:
		var t_chain := _chain(d["target_ikrig"]["chains"], cn, skeleton.find_bone, _t_parent)
		var s_chain := _chain(d["source_ikrig"]["chains"], _lookup(chain_map, cn), cs.find_bone, _s_parent)
		if t_chain.size() != 3 or s_chain.size() != 3:
			push_error("retarget: chain %s is not three bones" % cn)
			continue
		var ik := {"name": cn, "t": t_chain, "s": s_chain,
			"s_len0": (_s_rp_global[s_chain[2]].origin - _s_rp_global[s_chain[0]].origin).length(),
			"t_len0": (_t_rp_global[t_chain[2]].origin - _t_rp_global[t_chain[0]].origin).length(),
			"upper": _t_rp_local[t_chain[1]].origin.length(), "lower": _t_rp_local[t_chain[2]].origin.length(),
			"bts": bts.get(cn, {}), "curve": _lookup(d["curve_map"], cn)}
		# Knees and elbows bend one way about their Z (IK_UE5_Mannequin_Retarget: X and Y locked, preferred
		# angle on Z): the side, from the retarget pose.
		ik["bend_sign"] = _bend_sign(_t_rp_global, t_chain)
		var a = _lookup(align, cn)
		if a != null:
			ik["align"] = a
			ik["t_pole_axis"] = _most_different_axis(_t_rp_global, t_chain)
			ik["s_pole_axis"] = _most_different_axis(_s_rp_global, s_chain)
		_ik.append(ik)
	_S.resize(sn)
	_T.resize(_n)


## Sets chain_curves from the playing clips: each curve in the curve map, weighted by the clips' blend
## weights (players: the blend stack's [animation, time, weight]; sequence_of: animation -> sequence name
## as in sequences.json).
func update_curves(players: Array, sequence_of: Dictionary) -> void:
	var curves: Dictionary = data()["curves"]
	var curve_map: Dictionary = data()["curve_map"]
	for chain: String in curve_map:
		var curve_name: String = String(curve_map[chain]).to_lower()
		var v := 0.0
		for p: Array in players:
			var seq: Dictionary = curves.get(sequence_of.get(p[0], ""), {})
			if seq.has(curve_name):
				v += eval_curve(seq[curve_name], p[1]) * p[2]
		chain_curves[chain] = v


## FRichCurve::Eval for the exported keys (constant, linear or non-weighted cubic Bezier tangents).
static func eval_curve(c: Dictionary, t: float) -> float:
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
	var t0: float = times[i - 1]
	var dt: float = times[i] - t0
	var a := (t - t0) / dt
	match c.get("interp", "RCIM_Cubic"):
		"RCIM_Constant":
			return vals[i - 1]
		"RCIM_Linear":
			return lerpf(vals[i - 1], vals[i], a)
	var p0: float = vals[i - 1]
	var p3: float = vals[i]
	var p1: float = p0 + float(c["leave_tangents"][i - 1]) * dt / 3.0
	var p2: float = p3 - float(c["arrive_tangents"][i]) * dt / 3.0
	return bezier_interpolate(p0, p1, p2, p3, a)


## A bone of the clip skeleton (UEFN mannequin) in skeleton space for the pose before modifiers: the
## skeleton's joint rotations on the clip skeleton's bone offsets. What the databases measured.
static func source_pose(sk: Skeleton3D, bone: String) -> Transform3D:
	var cs := Mannequin.clip_skeleton()
	var xf := Transform3D.IDENTITY
	var b := cs.find_bone(bone)
	while b >= 0:
		var n := cs.get_bone_name(b)
		var mb := sk.find_bone(n)
		var local := cs.get_bone_rest(b)
		if mb >= 0:
			var pos := sk.get_bone_pose_position(mb) if n in Mannequin.POSITION_BONES else local.origin
			local = Transform3D(Basis(sk.get_bone_pose_rotation(mb)), pos)
		xf = local * xf
		b = cs.get_bone_parent(b)
	return xf


func _process_modification_with_delta(_delta: float) -> void:
	var sk := get_skeleton()
	if sk == null or _fk.is_empty():
		return
	# Source pose (the UEFN mannequin's), in skeleton space.
	for b in _s_names.size():
		var local := _s_rp_local[b]
		var mb := _s_from_t[b]
		if mb >= 0:
			var pos := sk.get_bone_pose_position(mb) if _s_animated_pos[b] else local.origin
			local = Transform3D(Basis(sk.get_bone_pose_rotation(mb)), pos)
		var p := _s_parent[b]
		_S[b] = local if p < 0 else _S[p] * local
	# Output starts at the retarget pose (FIKRetargetProcessor::RunRetargeter).
	for b in _n:
		_T[b] = _t_rp_global[b]
	# Pelvis Motion (RetargetPelvisTransform).
	var sp := _S[_s_pelvis]
	var rot := sp.basis.get_rotation_quaternion() * _s_rp_global[_s_pelvis].basis.get_rotation_quaternion().inverse() \
		* _t_rp_global[_t_pelvis].basis.get_rotation_quaternion()
	var pelvis_pos := sp.origin * _pelvis_scale + _pelvis_offset
	_T[_t_pelvis] = Transform3D(Basis(rot.normalized()), pelvis_pos)
	# FK chains, bones in hierarchy order: chain bones from the source, the rest keep their retarget-pose
	# local transform below their (retargeted) parent.
	var done := {}
	for b in _t_order:
		if b == _t_pelvis:
			continue
		var c := _fk_of_bone[b]
		if c < 0:
			_T[b] = _parent_of(_T, _t_parent, b) * _t_rp_local[b]
		elif not done.has(c):
			_decode_chain(_fk[c])
			done[c] = true
	# Locals of the FK result; the IK below only changes its limb bones.
	var locals: Array[Transform3D] = []
	locals.resize(_n)
	for b in _n:
		locals[b] = _parent_of(_T, _t_parent, b).affine_inverse() * _T[b]
	for ik in _ik:
		_solve_limb(ik, locals)
	for b in _n:
		sk.set_bone_pose_position(b, locals[b].origin)
		sk.set_bone_pose_rotation(b, locals[b].basis.get_rotation_quaternion())


## FChainDecoderFK::DecodePose for one chain: the source chain is re-hung from the target chain's parent
## (keeping the parents' retarget-pose offset), then each target bone takes the rotation change of the
## source at its place along the chain.
func _decode_chain(fk: Dictionary) -> void:
	var t_chain: PackedInt32Array = fk["t"]
	var s_chain: PackedInt32Array = fk["s"]
	var t_cp: int = fk["t_cp"]
	var s_cp: int = fk["s_cp"]
	var new_parent := Transform3D.IDENTITY
	if t_cp >= 0 and s_cp >= 0:
		new_parent = _T[t_cp] * _t_rp_global[t_cp].affine_inverse() * _s_rp_global[s_cp]
	var src: Array[Transform3D] = []
	for j in s_chain.size():
		var b := s_chain[j]
		var local := _parent_of(_S, _s_parent, b).affine_inverse() * _S[b]
		src.append((new_parent if j == 0 else src[j - 1]) * local)
	var s0: Array[Transform3D] = []
	for b in s_chain:
		s0.append(_s_rp_global[b])
	for i in t_chain.size():
		var b := t_chain[i]
		var cur: Transform3D
		var init: Transform3D
		if fk["rotation"] == "OneToOne":
			var k := mini(i, s_chain.size() - 1)
			cur = src[k]
			init = s0[k]
		else:
			var param: float = fk["t_params"][i]
			cur = _at_param(src, fk["s_params"], param)
			init = _at_param(s0, fk["s_params"], param)
		var delta := cur.basis.get_rotation_quaternion() * init.basis.get_rotation_quaternion().inverse()
		var out_rot := (delta * _t_rp_global[b].basis.get_rotation_quaternion()).normalized()
		var out_pos: Vector3
		if fk["translation"] == "GloballyScaled":
			out_pos = cur.origin * _pelvis_scale
		else:
			out_pos = _parent_of(_T, _t_parent, b) * _t_rp_local[b].origin
		_T[b] = Transform3D(Basis(out_rot), out_pos)


## Goal (FRunIKRigChain::Run, then FIKChainToBlend::Run), two-bone solve, then FPoleVectorMatcher.
func _solve_limb(ik: Dictionary, locals: Array[Transform3D]) -> void:
	var t: PackedInt32Array = ik["t"]
	var s: PackedInt32Array = ik["s"]
	var src_start := _S[s[0]].origin
	var src_end := _S[s[2]]
	# Run IK Rig: the source limb's direction, at the source's stretch of the target's length, from the
	# target's own start bone. Rotation: the source end's change from its retarget pose.
	var v := src_end.origin - src_start
	var s_len0: float = ik["s_len0"]
	var t_len0: float = ik["t_len0"]
	var goal_pos: Vector3 = _T[t[0]].origin + v.normalized() * (v.length() / s_len0) * t_len0
	var goal_rot := (src_end.basis.get_rotation_quaternion() * _s_rp_global[s[2]].basis.get_rotation_quaternion().inverse() \
		* _t_rp_global[t[2]].basis.get_rotation_quaternion()).normalized()
	# Blend to Source: toward the source end bone (plus the pelvis offset), by the asset's value lerped to
	# 1 by the chain's curve.
	var bts: Dictionary = ik["bts"]
	var amount: float = bts.get("blend_to_source", 0.0)
	if ik["curve"] != null:
		amount = lerpf(amount, 1.0, clampf(chain_curves.get(ik["name"], 0.0), 0.0, 1.0))
	var alpha: float = amount * float(bts.get("translation_alpha", 1.0))
	if alpha > 1e-4:
		var to := src_end.origin + _pelvis_offset * float(bts.get("apply_pelvis_offset", 0.0))
		goal_pos = goal_pos.lerp(to, alpha)
	# Two-bone solve with the middle joint hinged about its Z: the knee or elbow stays in the plane
	# its FK pose bends in.
	var root := _T[t[0]]
	var mid := root * locals[t[1]]
	var a: float = ik["upper"]
	var b: float = ik["lower"]
	var axis: Vector3 = goal_pos - root.origin
	var d := clampf(axis.length(), absf(a - b) + 1e-5, a + b - 1e-5)
	axis = axis.normalized()
	# The solve starts from the FK pose and moves it as little as it can: the knee stays in the plane of
	# the FK knee, or about the hinge axis when the FK limb is straight.
	# A straight or overstraightened FK limb bends forward about the hinge (the preferred angle).
	var hinge_side := mid.basis.z.normalized().cross(axis) * float(ik["bend_sign"])
	var side := (mid.origin - root.origin).slide(axis)
	if side.length() < 0.02 * a or side.dot(hinge_side) <= 0.0:
		side = hinge_side
	side = side.normalized()
	var x := (a * a - b * b + d * d) / (2.0 * d)
	var knee: Vector3 = root.origin + axis * x + side * sqrt(maxf(a * a - x * x, 0.0))
	var r1 := Quaternion((mid.origin - root.origin).normalized(), (knee - root.origin).normalized())
	var root_rot := (r1 * root.basis.get_rotation_quaternion()).normalized()
	var new_root := Transform3D(Basis(root_rot), root.origin)
	var new_mid := new_root * locals[t[1]]
	var end_now := new_mid * locals[t[2]]
	var r2 := Quaternion((end_now.origin - new_mid.origin).normalized(), (root.origin + axis * d - new_mid.origin).normalized())
	new_mid = Transform3D(Basis((r2 * new_mid.basis.get_rotation_quaternion()).normalized()), new_mid.origin)
	var end_pos: Vector3 = root.origin + axis * d
	# Pole Vector Alignment (legs): turn the chain about its root-to-end axis so the start bone's pole
	# axis lines up with the source's (FPoleVectorMatcher::MatchPoleVector). Unreal turns by the unsigned
	# angle; the solve above isn't Unreal's full-body solve, so the turn here takes the side that lines the
	# axes up, which matches Unreal's own retarget of the clips best (tools/checks/check_retarget_vs_unreal.gd).
	if ik.has("align"):
		var s_axis := (_S[s[2]].origin - _S[s[0]].origin).normalized()
		var s_pole := _S[s[0]].basis[ik["s_pole_axis"]].slide(s_axis).normalized()
		var t_pole := new_root.basis[ik["t_pole_axis"]].slide(axis).normalized()
		var align_settings: Dictionary = ik["align"]
		var turn := Quaternion(axis, t_pole.signed_angle_to(s_pole, axis) * float(align_settings["alpha"]))
		var mid_local := new_root.affine_inverse() * new_mid
		new_root = Transform3D(Basis((turn * new_root.basis.get_rotation_quaternion()).normalized()), root.origin)
		new_mid = new_root * mid_local
	locals[t[0]] = _parent_of(_T, _t_parent, t[0]).affine_inverse() * new_root
	locals[t[1]] = new_root.affine_inverse() * new_mid
	locals[t[2]] = new_mid.affine_inverse() * Transform3D(Basis(goal_rot), end_pos)
	_T[t[0]] = new_root
	_T[t[1]] = new_mid
	_T[t[2]] = Transform3D(Basis(goal_rot), end_pos)


# ------------------------------------------------------------------ setup helpers

static func _order(parents: PackedInt32Array) -> PackedInt32Array:
	var out := PackedInt32Array()
	var placed := {}
	while out.size() < parents.size():
		for b in parents.size():
			if not placed.has(b) and (parents[b] < 0 or placed.has(parents[b])):
				out.append(b)
				placed[b] = true
	return out


static func _globals(locals: Array[Transform3D], parents: PackedInt32Array, order: PackedInt32Array) -> Array[Transform3D]:
	var g: Array[Transform3D] = []
	g.resize(locals.size())
	for b in order:
		g[b] = locals[b] if parents[b] < 0 else g[parents[b]] * locals[b]
	return g


static func _parent_of(globals: Array[Transform3D], parents: PackedInt32Array, b: int) -> Transform3D:
	return Transform3D.IDENTITY if parents[b] < 0 else globals[parents[b]]


## Case-insensitive lookup (Unreal names are FNames).
static func _lookup(dict: Dictionary, key: String):
	for k: String in dict:
		if k.to_lower() == key.to_lower():
			return dict[k]
	return null


## Bones of a retarget chain from its start to its end bone.
static func _chain(chains: Dictionary, chain_name, find: Callable, parents: PackedInt32Array) -> PackedInt32Array:
	if chain_name == null:
		return PackedInt32Array()
	var found = _lookup(chains, chain_name)
	if found == null:
		return PackedInt32Array()
	var c: Dictionary = found
	var start: int = find.call(c["start"])
	var b: int = find.call(c["end"])
	var out := PackedInt32Array()
	while b >= 0:
		out.insert(0, b)
		if b == start:
			return out
		b = parents[b]
	return PackedInt32Array()


## FResolvedBoneChain::CalculateBoneParameters: each bone's distance along the chain, 0..1.
static func _params(globals: Array[Transform3D], chain: PackedInt32Array) -> PackedFloat32Array:
	var out := PackedFloat32Array()
	if chain.size() == 1:
		out.append(1.0)
		return out
	var dist := [0.0]
	for i in range(1, chain.size()):
		dist.append(dist[i - 1] + (globals[chain[i]].origin - globals[chain[i - 1]].origin).length())
	var total: float = maxf(dist[-1], 1e-8)
	for x: float in dist:
		out.append(x / total)
	return out


## FResolvedBoneChain::GetTransformAtChainParam.
static func _at_param(xf: Array[Transform3D], params: PackedFloat32Array, param: float) -> Transform3D:
	if params.size() == 1 or param < 1e-8:
		return xf[0]
	if param > 1.0 - 1e-8:
		return xf[-1]
	for i in range(1, params.size()):
		if params[i] <= param:
			continue
		var w := (param - params[i - 1]) / (params[i] - params[i - 1])
		var qa := xf[i - 1].basis.get_rotation_quaternion()
		var qb := xf[i].basis.get_rotation_quaternion()
		if qa.dot(qb) < 0.0:
			qb = -qb
		var q := (qa * (1.0 - w) + qb * w).normalized()  # FQuat::FastLerp
		return Transform3D(Basis(q), xf[i - 1].origin.lerp(xf[i].origin, w))
	return xf[-1]


## Which side of the root-to-end line the middle joint bends to, about its Z.
static func _bend_sign(globals: Array[Transform3D], chain: PackedInt32Array) -> float:
	var h := globals[chain[0]].origin
	var k := globals[chain[1]].origin
	var axis := (globals[chain[2]].origin - h).normalized()
	var side := globals[chain[1]].basis.z.normalized().cross(axis)
	return -1.0 if (k - h).dot(side) < 0.0 else 1.0


## FPoleVectorMatcher::GetMostDifferentAxis on the chain's start bone (0 x, 1 y, 2 z).
static func _most_different_axis(globals: Array[Transform3D], chain: PackedInt32Array) -> int:
	var normal := (globals[chain[-1]].origin - globals[chain[0]].origin).normalized()
	var best := 1
	var best_dot := 2.0
	for i in 3:
		var dd := absf(globals[chain[0]].basis[i].normalized().dot(normal))
		if dd < best_dot:
			best_dot = dd
			best = i
	return best
