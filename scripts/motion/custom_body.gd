# Shows another character in Manny's place. Manny keeps running everything (clips, retarget, foot
# placement, ragdoll) with his meshes hidden. A RetargetModifier3D, kept last on his skeleton, copies
# each bone's model-space turn from its rest onto the body's skeleton by bone name.
#
# The body needs UE5 mannequin bone names; its bone axes, bind pose (T or A) and size may differ.
# Bones Manny lacks (a cape's chains) follow their parent and swing as springs (SpringBoneSimulator3D).
# Its skeleton's rests are rebuilt so that each body bone follows the Manny bone of the same name
# with a fixed offset, measured with both bind poses lined up: the body is turned to face like Manny,
# and its limbs are swung onto Manny's bind-pose bone directions. Skinning uses the skin's bind
# poses, so changing the rests does not change the mesh.
class_name CustomBody
extends RefCounted

## Bones are swung toward this child when they have several (else the one non-twist child).
const AIM_CHILD := {"pelvis": "spine_01", "spine_05": "neck_01", "hand": "middle_metacarpal"}


## Puts the body at `path` on Manny (manny_body: what Mannequin.instantiate() returned).
static func attach(manny_body: Node3D, path: String) -> Skeleton3D:
	var ms := Mannequin.find_skeleton(manny_body)
	var body: Node3D = load(path).instantiate()
	var bs: Skeleton3D = body.find_children("*", "Skeleton3D", true, false)[0]

	# Manny's bind pose: his FBX's own rests (Mannequin.instantiate() replaced the rests on ms).
	var manny_src: Node3D = load(Mannequin.MESH).instantiate()
	var mbind := Mannequin.find_skeleton(manny_src)
	var n := bs.get_bone_count()
	var N: Array[Transform3D] = []   # Manny bind, global, per body bone
	var W: Array[Transform3D] = []   # body bind, global
	var M_rest: Array[Transform3D] = []  # Manny's current rest, global
	var extra: Array[int] = []  # bones Manny lacks
	for b in n:
		var bn := bs.get_bone_name(b)
		var mb := mbind.find_bone(bn)
		W.append(bs.get_bone_global_rest(b))
		if mb < 0 or ms.find_bone(bn) < 0:
			if bs.get_bone_parent(b) < 0:
				push_error("custom body: Manny has no bone %s" % bn)
				manny_src.free()
				body.free()
				return null
			extra.append(b)
			N.append(Transform3D())
			M_rest.append(Transform3D())
			continue
		N.append(mbind.get_bone_global_rest(mb))
		M_rest.append(ms.get_bone_global_rest(ms.find_bone(bn)))
	manny_src.free()

	# Body space to Manny space: a turn that lines up up (feet to head) and left (right hip to left hip).
	var turn := _frame_of(N, bs) * _frame_of(W, bs).inverse()
	# Size: hip height above the ball of the foot, so the legs reach the ground like Manny's.
	var body_scale := _hip_height(N, bs) / _hip_height(W, bs)

	# The body's bind pose turned into Manny space with each limb swung onto Manny's bone directions.
	var order: Array = Array(_order(bs))
	var G: Array[Basis] = []
	G.resize(n)
	order = Array(order).filter(func(b: int) -> bool: return not b in extra)
	for b in order:
		var p := bs.get_bone_parent(b)
		var local := bs.get_bone_rest(b).basis.orthonormalized()
		G[b] = (turn * W[b].basis.orthonormalized()) if p < 0 else G[p] * local
		var c := _aim_child(bs, b, extra)
		if c >= 0:
			var to_child := G[b] * bs.get_bone_rest(c).origin
			var want := N[c].origin - N[b].origin
			if to_child.length() > 1e-4 and want.length() > 1e-4:
				G[b] = Basis(Quaternion(to_child.normalized(), want.normalized())) * G[b]
	# Rests: Manny's current rest times the fixed offset; positions stay the body's own. Bones Manny
	# lacks keep their own rests, so they stay where they were bound relative to their parent.
	var rest_g: Array[Basis] = []
	rest_g.resize(n)
	for b in order:
		var offset := N[b].basis.orthonormalized().inverse() * G[b]
		rest_g[b] = (M_rest[b].basis.orthonormalized() * offset).orthonormalized()
	for b in order:
		var p := bs.get_bone_parent(b)
		var origin := (turn * W[b].origin) if p < 0 else bs.get_bone_rest(b).origin
		var basis := rest_g[b] if p < 0 else rest_g[p].inverse() * rest_g[b]
		bs.set_bone_rest(b, Transform3D(basis, origin))
	# The size goes into the skeleton's bone positions and the skin, not a node scale: the springs
	# measure bone lengths in skeleton units and positions in world units.
	for b in n:
		var r := bs.get_bone_rest(b)
		r.origin *= body_scale
		bs.set_bone_rest(b, r)
	var grow := Transform3D(Basis.from_scale(Vector3.ONE * body_scale), Vector3.ZERO)
	for mi: MeshInstance3D in bs.find_children("*", "MeshInstance3D", true, false):
		if mi.skin == null:
			continue
		mi.skin = mi.skin.duplicate()  # shared by every instance of the body
		for i in mi.skin.get_bind_count():
			mi.skin.set_bind_pose(i, grow * mi.skin.get_bind_pose(i))
	# Moves the body so its hip joints sit on Manny's at rest (a model's hips needn't be over its root
	# bone), so the legs reach where his do.
	var root := bs.get_parentless_bones()[0]
	var root_rest := bs.get_bone_rest(root)
	root_rest.origin += _hips(ms) - _hips(bs)
	bs.set_bone_rest(root, root_rest)
	bs.reset_bone_poses()
	bs.motion_scale = ms.motion_scale

	var profile := SkeletonProfile.new()
	profile.bone_size = order.size()
	for i in order.size():
		profile.set_bone_name(i, bs.get_bone_name(order[i]))
	_add_springs(bs, extra, body_scale)
	var modifier := RetargetModifier3D.new()
	modifier.name = "CustomBody_" + path.get_file().get_basename()
	modifier.set_meta("body_path", path)
	modifier.profile = profile
	bs.get_parent().remove_child(bs)
	body.free()
	bs.name = "Body"
	bs.transform = Transform3D.IDENTITY
	modifier.add_child(bs)
	ms.add_child(modifier)
	# Last modifier, so it copies the final pose (after the retarget, feet and ragdoll).
	ms.child_entered_tree.connect(func(_c: Node) -> void: _keep_last.call_deferred(ms, modifier))
	for c in ms.get_children():
		if c is MeshInstance3D:
			(c as MeshInstance3D).visible = false
	return bs


static func _keep_last(ms: Skeleton3D, modifier: Node) -> void:
	if is_instance_valid(modifier) and modifier.get_parent() == ms and modifier.get_index() != ms.get_child_count() - 1:
		ms.move_child(modifier, -1)


static func _bone(bs: Skeleton3D, xf: Array[Transform3D], bone_name: String) -> Vector3:
	return xf[bs.find_bone(bone_name)].origin


## Columns: left, up, forward (from the hips and the head over the feet).
static func _frame_of(xf: Array[Transform3D], bs: Skeleton3D) -> Basis:
	var feet := (_bone(bs, xf, "foot_l") + _bone(bs, xf, "foot_r")) * 0.5
	var up := (_bone(bs, xf, "head") - feet).normalized()
	var left := (_bone(bs, xf, "thigh_l") - _bone(bs, xf, "thigh_r")).slide(up).normalized()
	return Basis(left, up, left.cross(up))


static func _hips(s: Skeleton3D) -> Vector3:
	return (s.get_bone_global_rest(s.find_bone("thigh_l")).origin + s.get_bone_global_rest(s.find_bone("thigh_r")).origin) * 0.5


static func _hip_height(xf: Array[Transform3D], bs: Skeleton3D) -> float:
	var up := _frame_of(xf, bs).y
	return (_bone(bs, xf, "thigh_l") - _bone(bs, xf, "ball_l")).dot(up)


static func _aim_child(bs: Skeleton3D, b: int, extra: Array[int]) -> int:
	var bn := bs.get_bone_name(b)
	if bn == "root" or bn.contains("twist"):
		return -1
	var kids := Array(bs.get_bone_children(b)).filter(func(c: int) -> bool: return not bs.get_bone_name(c).contains("twist") and not c in extra)
	if kids.size() == 1:
		return kids[0]
	var side := bn.substr(bn.length() - 2) if bn.ends_with("_l") or bn.ends_with("_r") else ""
	var want: String = AIM_CHILD.get(bn.trim_suffix(side), "")
	return bs.find_bone(want + side) if want != "" else -1


static func _order(bs: Skeleton3D) -> PackedInt32Array:
	var out := PackedInt32Array()
	var stack := Array(bs.get_parentless_bones())
	while not stack.is_empty():
		var b: int = stack.pop_back()
		out.append(b)
		stack.append_array(Array(bs.get_bone_children(b)))
	return out


## Capsules the springs keep out of, bone to bone. Each is as thick as the body's mesh around it,
## but never reaches a spring bone's rest position (so the rest pose isn't pushed).
const SPRING_COLLIDERS := [["pelvis", "spine_03"], ["spine_03", "neck_01"], ["thigh_l", "calf_l"], ["thigh_r", "calf_r"], ["calf_l", "foot_l"], ["calf_r", "foot_r"]]
const SPRING_RADIUS := 0.035  # the spring bones' own thickness, metres


## One spring chain from each bone Manny lacks whose parent he has, down its first children: stiff
## and still at the top, freer toward the end.
static func _add_springs(bs: Skeleton3D, extra: Array[int], body_scale: float) -> void:
	var roots := extra.filter(func(b: int) -> bool: return not bs.get_bone_parent(b) in extra)
	if roots.is_empty():
		return
	var sim := SpringBoneSimulator3D.new()
	sim.name = "Springs"
	sim.setting_count = roots.size()
	var stiff_curve := Curve.new()
	stiff_curve.add_point(Vector2(0, 1))
	stiff_curve.add_point(Vector2(1, 0.3))
	var joints: Array[Vector3] = []  # spring bones at rest, skeleton space
	for i in roots.size():
		var end: int = roots[i]
		joints.append(bs.get_bone_global_rest(end).origin)
		while bs.get_bone_children(end).size() > 0:
			end = bs.get_bone_children(end)[0]
			joints.append(bs.get_bone_global_rest(end).origin)
		sim.set_root_bone(i, roots[i])
		sim.set_end_bone(i, end)
		sim.set_extend_end_bone(i, true)
		sim.set_end_bone_length(i, bs.get_bone_rest(end).origin.length())
		sim.set_radius(i, SPRING_RADIUS)
		sim.set_stiffness(i, 3.0)
		sim.set_stiffness_damping_curve(i, stiff_curve)
		sim.set_drag(i, 0.75)
		sim.set_gravity(i, 3.0)
	for pair: Array in SPRING_COLLIDERS:
		var b := bs.find_bone(pair[0])
		var c := bs.find_bone(pair[1])
		if b < 0 or c < 0:
			continue
		var head := bs.get_bone_global_rest(b).origin
		var tail := bs.get_bone_global_rest(c).origin
		var radius := _mesh_radius(bs, b, c) * body_scale
		for j in joints:
			radius = minf(radius, _to_segment(j, head, tail) - SPRING_RADIUS - 0.01)
		if radius <= 0.01:
			continue
		var to_child: Vector3 = bs.get_bone_global_rest(b).basis.inverse() * (tail - head)
		var col := SpringBoneCollisionCapsule3D.new()
		col.bone = b
		col.radius = radius
		col.height = to_child.length() + radius * 2.0
		col.position_offset = to_child * 0.5
		col.rotation_offset = Quaternion(Vector3.UP, to_child.normalized())
		sim.add_child(col)
	bs.add_child(sim)


## How far the mesh weighted to the bones from b down to c (and their twist bones) reaches from the
## line b to c, in the mesh's bind pose (80th percentile, the mesh's units).
static func _mesh_radius(bs: Skeleton3D, b: int, c: int) -> float:
	var bones := {}
	var k := bs.get_bone_parent(c)
	while k >= 0:
		bones[k] = true
		for ch in bs.get_bone_children(k):
			if bs.get_bone_name(ch).contains("twist"):
				bones[ch] = true
		if k == b:
			break
		k = bs.get_bone_parent(k)
	var d := PackedFloat32Array()
	for mi: MeshInstance3D in bs.find_children("*", "MeshInstance3D", true, false):
		if mi.skin == null:
			continue
		var bind_bone := PackedInt32Array()
		var joint := {}  # bone: where the skin binds it, mesh space
		for i in mi.skin.get_bind_count():
			var bb := mi.skin.get_bind_bone(i)
			bb = bb if bb >= 0 else bs.find_bone(mi.skin.get_bind_name(i))
			bind_bone.append(bb)
			joint[bb] = mi.skin.get_bind_pose(i).affine_inverse().origin
		if not (joint.has(b) and joint.has(c)):
			continue
		var head: Vector3 = joint[b]
		var tail: Vector3 = joint[c]
		for si in mi.mesh.get_surface_count():
			var arr := mi.mesh.surface_get_arrays(si)
			var verts: PackedVector3Array = arr[Mesh.ARRAY_VERTEX]
			var vb: PackedInt32Array = arr[Mesh.ARRAY_BONES]
			var vw: PackedFloat32Array = arr[Mesh.ARRAY_WEIGHTS]
			var per := vb.size() / verts.size()
			for v in verts.size():
				var top := 0
				for w in per:
					if vw[v * per + w] > vw[v * per + top]:
						top = w
				if bones.has(bind_bone[vb[v * per + top]]):
					d.append(_to_segment(verts[v], head, tail))
	if d.is_empty():
		return 0.0
	d.sort()
	return d[int(d.size() * 0.8)]


static func _to_segment(p: Vector3, a: Vector3, b: Vector3) -> float:
	var ab := b - a
	var t := clampf((p - a).dot(ab) / maxf(ab.length_squared(), 1e-8), 0.0, 1.0)
	return p.distance_to(a + ab * t)
