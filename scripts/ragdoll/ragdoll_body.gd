# The sample's physics asset PA_UEFN_Mannequin on the character's skeleton (one PhysicalBone3D per
# body under a PhysicalBoneSimulator3D, the constraints as Jolt 6DOF joints from the asset's own
# frames) and the PhysicsControlComponent of PCA_SandboxCharacter: per body a world-space control and
# a parent-space control, switched by the profiles Kinematic / PhysicalAnimation / Ragdoll
# (PhysicsControlComponentImpl.cpp, PhysicsControlHelpers.h).
#
# Units: the asset is in Unreal bone space (cm). The skeleton's bone frames are Unreal's with Y
# negated, so positions/axes map (x, y, z) -> (x, -y, z) / 100 and quaternions (x, y, z, w) ->
# (-x, y, -z, w). Unreal capsules lie along their local Z, Godot's along Y. As in the sample, the bodies
# simulate the UEFN mannequin the asset and the clips were made for (BP_Manny retargets the UEFN
# mesh's pose, physics included, onto Manny afterwards): the bone offsets are the clip skeleton's
# (ClipGeometry), not Manny's longer ones (spine_05 19.4 cm up spine_04 instead of 10.0, calves 43.3 vs
# 39.0 cm), which put the feet 1 to 3 cm into the floor, where the foot bodies were pushed out.
#
# Controls (acceleration mode, mass independent): strength s -> w = 2 pi s, k = w^2,
# d = 2 * ratio * w (PhysicsControlHelpers.h), then Chaos's drive conversion: angular k and d x1.5,
# linear x1 (ChaosConstraintSettings.cpp, PhysInterface_Chaos UpdateAngularDrive); target = the animated
# pose (bUseSkeletalAnimation), target velocity = its change over the tick. Chaos solves them as soft
# joint drives inside the solver (implicit: the spring holds k * error against gravity and contacts).
# Here they are Jolt 6DOF springs (position motors, a soft constraint solved with the joints and
# contacts) with stiffness/damping = k, d times the effective mass/inertia along each axis (Chaos's
# acceleration mode, InitRotationDatasMass), re-set every tick; the velocity target is folded into
# the equilibrium (k (x_t - x) + d (v_t - v) = k ((x_t + d/k v_t) - x) - d v):
#  - world-space controls: per body a 6DOF joint to the world, all axes free, linear + angular springs;
#  - parent-space controls: the angular springs of the asset's joint between child and parent body.
# The asset's LimitViolationResponse is WidenLimits: a joint whose drive target lies past a limit gets
# the limit widened to the target + 0.5 deg (ConstraintInstance::WidenLimitsForDriveTarget), every tick.
extends RefCounted

const DATA := "res://extracted/data/physics_asset.json"
const ASSET := "PA_UEFN_Mannequin"
const CM := 0.01
## Ragdoll bodies' own collision layer (10); they collide with layer 1 (the world) and, for the leg
## pairs only, with each other.
const LAYER := 1 << 9
const MASK := 1 | (1 << 9)
const FRICTION := 1.75            # PM_UEFN_Mannequin (all bodies but neck_02 and head)
const DEFAULT_FRICTION := 0.7     # Unreal's default physical material
## neck_02 has no mass override: Unreal's volume mass (448.5 cm3 at 1 g/cm3) ^ 0.75.
const NECK_02_MASS := 0.55
const WIDEN_MARGIN := 0.5         # degrees
const MASS_CONDITIONING := 0.3
## Chaos's conversion of joint drive stiffness/damping (ChaosConstraintSettings.cpp
## JointConstraintDefaults: AngularDriveStiffnessScale = AngularDriveDampingScale = 1.5,
## LinearDrive*Scale = 1.0), applied to every FConstraintInstance drive, the PCC's controls included.
const ANGULAR_DRIVE_STIFFNESS_SCALE := 1.5
const ANGULAR_DRIVE_DAMPING_SCALE := 1.5
const LINEAR_DRIVE_STIFFNESS_SCALE := 1.0
const LINEAR_DRIVE_DAMPING_SCALE := 1.0
## Drive targets this far (m) from their body count as a teleport (bHasJustTeleported): the bodies
## jump to the pose instead of being dragged there.
const TELEPORT_DISTANCE := 1.0
## A root target moving faster than this (m/s, rad/s) in one tick is a placement, not animation: no
## target velocities that tick.
const JUMP_SPEED := 15.0
const JUMP_TURN_RATE := 20.0
## The angular velocity targets go into the springs' equilibria as a lead of d/k * w_t; past a quarter
## turn a rotation lead no longer means "faster" (it wraps), so it is capped there (rad).
const MAX_LEAD := PI * 0.5
## SetPhysicsProfile("Ragdoll"): EnableCollisionBetweenBodyArrays(left leg, right leg). Every other
## pair is kept apart (the asset's collision disable table is not exported).
const LEFT_LEG := ["thigh_l", "calf_l", "foot_l"]
const RIGHT_LEG := ["thigh_r", "calf_r", "foot_r"]
const FEET := ["foot_l", "foot_r"]
const LIMBS := {
	"Head": ["neck_01", "neck_02", "head"],
	"Torso": ["pelvis", "spine_01", "spine_02", "spine_03", "spine_04", "spine_05"],
	"Arms": ["clavicle_l", "upperarm_l", "lowerarm_l", "hand_l", "clavicle_r", "upperarm_r", "lowerarm_r", "hand_r"],
	"Legs": ["thigh_l", "calf_l", "foot_l", "thigh_r", "calf_r", "foot_r"],
}
const LIMB_INDEX := {"Head": 0, "Torso": 1, "Arms": 2, "Legs": 3}
## The bone whose offset gives a body bone's length (to fit the asset to Manny's proportions).
const LENGTH_CHILD := {
	"spine_01": "spine_02", "spine_02": "spine_03", "spine_03": "spine_04", "spine_04": "spine_05",
	"spine_05": "neck_01", "neck_01": "neck_02", "neck_02": "head",
	"clavicle_l": "upperarm_l", "upperarm_l": "lowerarm_l", "lowerarm_l": "hand_l",
	"clavicle_r": "upperarm_r", "upperarm_r": "lowerarm_r", "lowerarm_r": "hand_r",
	"thigh_l": "calf_l", "calf_l": "foot_l", "thigh_r": "calf_r", "calf_r": "foot_r",
}
## PCA_SandboxCharacter profiles (spec 1.3). Strengths in Hz; the parent-space strength is also scaled
## per limb (Ragdoll_Strength_* curves, Ragdoll profile only).
const PROFILES := {
	"Kinematic": {"simulated": false},
	"PhysicalAnimation": {"simulated": true, "gravity": 0.0,
		"world_lin": 3.0, "world_ang": 3.0, "world_ratio": 1.0, "feet_lin": 10.0, "feet_ang": 10.0,
		"parent_ang": 15.0, "parent_ratio": 3.0},
	"Ragdoll": {"simulated": true, "gravity": 1.0,
		"world_lin": 0.0, "world_ang": 0.0, "world_ratio": 1.0, "feet_lin": 0.0, "feet_ang": 0.0,
		"parent_ang": 10.0, "parent_ratio": 3.0},
}

var skeleton: Skeleton3D
var simulator: PhysicalBoneSimulator3D
## Body bones, parents first; index i is used by every per-body array.
var names: PackedStringArray
var bodies: Array[PhysicalBone3D] = []
var bone_ids: PackedInt32Array
## Index of the physical parent body, -1 for the pelvis.
var parent: PackedInt32Array
## Limb (0 head, 1 torso, 2 arms, 3 legs) of each body.
var limb: PackedInt32Array
var is_foot: PackedByteArray
## Rotation of the body frame in its bone frame (body_offset).
var offset_rot: Array[Quaternion] = []
## Joint per child body: frames in the parent and child body spaces, the asset's limits
## (twist, swing2, swing1) rad, and the limits now set (widened).
var joint_parent_frame: Array[Transform3D] = []
var joint_child_frame: Array[Transform3D] = []
var joint_limits: Array[Vector3] = []
var joint_set_limits: Array[Vector3] = []
var joint_rids: Array[RID] = []
var _joint_of := {}   # body index -> joint RID
## Per body a 6DOF joint to the world, all axes free, carrying the world-space controls' springs.
var _world_joint: Array[RID] = []
var mass: PackedFloat32Array
var friction: PackedFloat32Array
var total_mass := 0.0
var simulating := false
var profile := "Kinematic"
var params: Dictionary = PROFILES["Kinematic"]
## Joint and angles of the last max_limit_violation() (diagnostics).
var worst_joint := ""
## Parent-space target of each body (child body rel. parent body) and its strength (Hz) at the last
## drive(), for the bend checks (tools/checks/test_ragdoll_bend.gd).
var last_rel_target: Array = []
var last_strength := PackedFloat32Array()

var _prev_local: Array = []     # last parent-space targets (child body rel. parent body)
var _prev_world: Array = []     # last world-space targets (body frames)
var _exclude: CollisionObject3D
## Puts the bones on the bodies as they are now; runs right after the simulator (see BodyPose).
var pose_writer: SkeletonModifier3D
## Puts the bones at the clip skeleton's offsets; runs first (see ClipGeometry).
var geometry: SkeletonModifier3D
## Per skeleton bone: its offset from its parent on the clip skeleton (the UEFN mannequin), and whether
## its position is animated (Mannequin.POSITION_BONES) instead.
var offsets := PackedVector3Array()
var animated_pos := PackedByteArray()


## The pose under the bodies is the clip skeleton's: each bone at its UEFN offset, the animated
## positions kept. The retarget reads only rotations and the animated positions, so Manny is unchanged
## by it; the simulator also places bodies that start simulating from this pose.
class ClipGeometry extends SkeletonModifier3D:
	var body

	func _process_modification_with_delta(_delta: float) -> void:
		var sk := get_skeleton()
		for b in body.offsets.size():
			if not body.animated_pos[b]:
				sk.set_bone_pose_position(b, body.offsets[b])


## The simulator's bone poses come from the bodies' state callbacks, which Godot delivers at the start
## of the next physics tick (Main::iteration: sync, flush_queries, physics_process, step), so the mesh
## drew the bodies of the step before over this frame's animation: a frame behind, 10 deg at the wrist
## in a run. Unreal blends the bodies of this frame's simulation (BlendInPhysics after the physics
## tick). This writes the bodies' current transforms over the simulator's.
class BodyPose extends SkeletonModifier3D:
	var body

	func _process_modification_with_delta(_delta: float) -> void:
		if not body.simulating:
			return
		var sk := get_skeleton()
		var inv := sk.global_transform.affine_inverse()
		for i in body.bodies.size():
			sk.set_bone_global_pose(body.bone_ids[i], (inv * body.bone_world(i)).orthonormalized())


func _init(skel: Skeleton3D, exclude: CollisionObject3D) -> void:
	skeleton = skel
	_exclude = exclude
	var pa: Dictionary = JSON.parse_string(FileAccess.get_file_as_string(DATA))["physics_assets"][ASSET]
	var by_bone := {}
	for b: Dictionary in pa["bodies"]:
		by_bone[b["bone"]] = b
	var constraints := {}
	for c: Dictionary in pa["constraints"]:
		constraints[c["child_bone"]] = c
	var cs := Mannequin.clip_skeleton()
	for b in skeleton.get_bone_count():
		var c := cs.find_bone(skeleton.get_bone_name(b))
		offsets.append(cs.get_bone_rest(c).origin if c >= 0 else skeleton.get_bone_rest(b).origin)
		animated_pos.append(1 if skeleton.get_bone_name(b) in Mannequin.POSITION_BONES else 0)
	geometry = ClipGeometry.new()
	geometry.name = "RagdollClipGeometry"
	geometry.body = self
	skeleton.add_child(geometry)
	simulator = PhysicalBoneSimulator3D.new()
	simulator.name = "RagdollSimulator"
	skeleton.add_child(simulator)
	pose_writer = BodyPose.new()
	pose_writer.name = "RagdollBodyPose"
	pose_writer.body = self
	skeleton.add_child(pose_writer)
	for bone in skeleton.get_bone_count():
		var bone_name := skeleton.get_bone_name(bone)
		if by_bone.has(bone_name):
			_add_body(bone, by_bone[bone_name], constraints)
	for i in names.size():
		var p := skeleton.get_bone_parent(bone_ids[i])
		var pi := -1
		while p >= 0 and pi < 0:
			pi = names.find(skeleton.get_bone_name(p))
			p = skeleton.get_bone_parent(p)
		parent.append(pi)
		var l := 1
		for limb_name: String in LIMBS:
			if (LIMBS[limb_name] as Array).has(names[i]):
				l = LIMB_INDEX[limb_name]
		limb.append(l)
		is_foot.append(1 if FEET.has(names[i]) else 0)
		_add_joint_data(i, constraints.get(names[i], {}))
	for i in bodies.size():
		if exclude != null:
			bodies[i].add_collision_exception_with(exclude)
		for j in range(i + 1, bodies.size()):
			var legs := (LEFT_LEG.has(names[i]) and RIGHT_LEG.has(names[j])) or (RIGHT_LEG.has(names[i]) and LEFT_LEG.has(names[j]))
			if not legs:
				bodies[i].add_collision_exception_with(bodies[j])


static func to_glb(v: Array) -> Vector3:
	return Vector3(float(v[0]), -float(v[1]), float(v[2]))


## Unreal FRotator (pitch, yaw, roll degrees) to the glb-space quaternion.
static func rotator_to_glb(r: Array) -> Quaternion:
	var p := deg_to_rad(float(r[0])) * 0.5
	var y := deg_to_rad(float(r[1])) * 0.5
	var ro := deg_to_rad(float(r[2])) * 0.5
	var sp := sin(p); var cp := cos(p); var sy := sin(y); var cy := cos(y); var sr := sin(ro); var cr := cos(ro)
	var q := Quaternion(cr * sp * sy - sr * cp * cy, -cr * sp * cy - sr * cp * sy, cr * cp * sy - sr * sp * cy, cr * cp * cy + sr * sp * sy)
	return Quaternion(-q.x, q.y, -q.z, q.w).normalized()


## How much longer this skeleton's bone is than the asset's (1 when unknown).
func _length_ratio(bone_name: String, constraints: Dictionary) -> float:
	var child: String = LENGTH_CHILD.get(bone_name, "")
	var c: Dictionary = constraints.get(child, {})
	var b := skeleton.find_bone(child)
	if c.is_empty() or b < 0:
		return 1.0
	var asset_len := (to_glb(c["frame2"]["Pos"]) * CM).length()
	if asset_len < 1e-3:
		return 1.0
	return offsets[b].length() / asset_len


func _add_body(bone: int, def: Dictionary, constraints: Dictionary) -> void:
	var s: Dictionary = def["shapes"][0]
	var inst: Dictionary = def["body_instance"]
	var ratio := _length_ratio(def["bone"], constraints)
	var center := to_glb(s["Center"]) * CM
	center.x *= ratio
	var xf := Transform3D(Basis(rotator_to_glb(s["Rotation"])), center)
	var shape: Shape3D
	if s["type"] == "capsule":
		var c := CapsuleShape3D.new()
		c.radius = float(s["Radius"]) * CM
		var length := float(s["Length"]) * CM
		# Capsules along the bone (limbs) stretch with it; across the bone (spine) they don't.
		var along := absf((xf.basis * Vector3(0, 0, 1)).x)
		length *= lerpf(1.0, ratio, along)
		c.height = length + 2.0 * c.radius
		shape = c
		xf.basis = xf.basis * Basis(Vector3.RIGHT, PI * 0.5)  # Godot's capsule axis Y onto Unreal's Z
	else:
		var b := BoxShape3D.new()
		b.size = Vector3(float(s["X"]), float(s["Y"]), float(s["Z"])) * CM
		shape = b
	var body := PhysicalBone3D.new()
	body.name = def["bone"]
	body.bone_name = def["bone"]
	body.body_offset = xf
	var m := float(inst["MassInKgOverride"]) if inst.get("bOverrideMass", false) else NECK_02_MASS
	body.mass = m
	friction.append(FRICTION if def.get("PhysMaterial") != null else DEFAULT_FRICTION)
	body.friction = minf(friction[-1], 1.0)  # the node clamps to 1; the server gets the real value
	body.bounce = 0.0
	body.linear_damp_mode = PhysicalBone3D.DAMP_MODE_REPLACE
	body.linear_damp = float(inst.get("LinearDamping", 0.01))
	body.angular_damp_mode = PhysicalBone3D.DAMP_MODE_REPLACE
	body.angular_damp = float(inst.get("AngularDamping", 0.0))
	body.can_sleep = false
	body.collision_layer = LAYER
	body.collision_mask = MASK
	var cs := CollisionShape3D.new()
	cs.shape = shape
	body.add_child(cs)
	simulator.add_child(body)
	bodies.append(body)
	names.append(def["bone"])
	bone_ids.append(bone)
	offset_rot.append(xf.basis.get_rotation_quaternion())
	mass.append(m)
	total_mass += m


# Constraint frames: X = PriAxis, Y = SecAxis, Z = X x Y; frame1 in the child bone, frame2 in the parent
# bone (ConstraintInstance.h), frame2's position being where the child bone sits on this skeleton.
# Limits: X twist, Y swing2, Z swing1.
func _add_joint_data(i: int, c: Dictionary) -> void:
	if c.is_empty() or parent[i] < 0:
		joint_parent_frame.append(Transform3D.IDENTITY)
		joint_child_frame.append(Transform3D.IDENTITY)
		joint_limits.append(Vector3.ZERO)
		joint_set_limits.append(Vector3.ZERO)
		return
	var f1 := _frame(c["frame1"])
	f1.origin = Vector3.ZERO
	var f2 := _frame(c["frame2"])
	f2.origin = offsets[bone_ids[i]]
	joint_child_frame.append(bodies[i].body_offset.affine_inverse() * f1)
	joint_parent_frame.append(bodies[parent[i]].body_offset.affine_inverse() * f2)
	var p: Dictionary = c["profile"]
	var lim := Vector3(
		deg_to_rad(float(p["TwistLimit"]["TwistLimitDegrees"])),
		deg_to_rad(float(p["ConeLimit"]["Swing2LimitDegrees"])),
		deg_to_rad(float(p["ConeLimit"]["Swing1LimitDegrees"])))
	joint_limits.append(lim)
	joint_set_limits.append(lim)


static func _frame(f: Dictionary) -> Transform3D:
	var x := to_glb(f["PriAxis"]).normalized()
	var y := to_glb(f["SecAxis"])
	y = (y - x * x.dot(y)).normalized()
	return Transform3D(Basis(x, y, x.cross(y)), to_glb(f["Pos"]) * CM)


# ------------------------------------------------------------------ profiles

## SetPhysicsProfile: Kinematic stops the bodies; PhysicalAnimation and Ragdoll simulate them (from
## the current pose with `velocities` [linear, angular] per body when they were not simulating).
func set_profile(name: String, velocities: Array = []) -> void:
	profile = name
	params = PROFILES[name]
	if not params["simulated"]:
		_stop()
		return
	if not simulating:
		_start(velocities)
	# The world-space controls come back on with the next drive() of a profile that has them.
	for i in bodies.size():
		_set_world_springs(i, false)
	_prev_world.clear()
	set_gravity_scale(params["gravity"])


func _start(velocities: Array) -> void:
	simulator.physical_bones_start_simulation()
	for i in bodies.size():
		var rid := bodies[i].get_rid()
		PhysicsServer3D.body_set_enable_continuous_collision_detection(rid, true)
		PhysicsServer3D.body_set_param(rid, PhysicsServer3D.BODY_PARAM_FRICTION, friction[i])
		if i < velocities.size():
			PhysicsServer3D.body_set_state(rid, PhysicsServer3D.BODY_STATE_LINEAR_VELOCITY, velocities[i][0])
			PhysicsServer3D.body_set_state(rid, PhysicsServer3D.BODY_STATE_ANGULAR_VELOCITY, velocities[i][1])
	_condition_inertia()
	for i in bodies.size():
		if parent[i] < 0:
			continue
		var j := PhysicsServer3D.joint_create()
		PhysicsServer3D.joint_make_generic_6dof(j, bodies[parent[i]].get_rid(), joint_parent_frame[i], bodies[i].get_rid(), joint_child_frame[i])
		for axis in 3:
			PhysicsServer3D.generic_6dof_joint_set_flag(j, axis, PhysicsServer3D.G6DOF_JOINT_FLAG_ENABLE_LINEAR_LIMIT, true)
			PhysicsServer3D.generic_6dof_joint_set_param(j, axis, PhysicsServer3D.G6DOF_JOINT_LINEAR_LOWER_LIMIT, 0.0)
			PhysicsServer3D.generic_6dof_joint_set_param(j, axis, PhysicsServer3D.G6DOF_JOINT_LINEAR_UPPER_LIMIT, 0.0)
			PhysicsServer3D.generic_6dof_joint_set_flag(j, axis, PhysicsServer3D.G6DOF_JOINT_FLAG_ENABLE_ANGULAR_LIMIT, true)
		PhysicsServer3D.joint_disable_collisions_between_bodies(j, true)
		joint_rids.append(j)
		_joint_of[i] = j
		joint_set_limits[i] = Vector3(-1, -1, -1)
		_set_limits(i, joint_limits[i])
	for i in bodies.size():
		var wj := PhysicsServer3D.joint_create()
		PhysicsServer3D.joint_make_generic_6dof(wj, bodies[i].get_rid(), Transform3D.IDENTITY, RID(), Transform3D.IDENTITY)
		for axis in 3:
			PhysicsServer3D.generic_6dof_joint_set_flag(wj, axis, PhysicsServer3D.G6DOF_JOINT_FLAG_ENABLE_LINEAR_LIMIT, false)
			PhysicsServer3D.generic_6dof_joint_set_flag(wj, axis, PhysicsServer3D.G6DOF_JOINT_FLAG_ENABLE_ANGULAR_LIMIT, false)
		_world_joint.append(wj)
	_prev_local.clear()
	_prev_world.clear()
	simulating = true


## Frees the joints (call when the character leaves the tree).
func release() -> void:
	_stop()


func _stop() -> void:
	if not simulating:
		return
	for j in joint_rids:
		PhysicsServer3D.free_rid(j)
	joint_rids.clear()
	for j in _world_joint:
		PhysicsServer3D.free_rid(j)
	_world_joint.clear()
	_joint_of.clear()
	simulator.physical_bones_stop_simulation()
	simulating = false


func _set_limits(i: int, lim: Vector3) -> void:
	if (joint_set_limits[i] - lim).length_squared() < 1e-8:
		return
	joint_set_limits[i] = lim
	var j: RID = _joint_of[i]
	for axis in 3:
		PhysicsServer3D.generic_6dof_joint_set_param(j, axis, PhysicsServer3D.G6DOF_JOINT_ANGULAR_LOWER_LIMIT, -lim[axis])
		PhysicsServer3D.generic_6dof_joint_set_param(j, axis, PhysicsServer3D.G6DOF_JOINT_ANGULAR_UPPER_LIMIT, lim[axis])


## The asset's constraints have bEnableMassConditioning (Chaos scales the inertia of a light body
## against its heavy neighbour inside the joint solve). Jolt has no such option, and neck_02
## (0.55 kg between two 2.5 kg bodies) spun at Jolt's 47 rad/s cap on every landing; here each body's
## inertia is raised to at least MASS_CONDITIONING of its joint neighbours' (mass is unchanged).
func _condition_inertia() -> void:
	var inertia: Array[float] = []
	for i in bodies.size():
		var inv := state(i).inverse_inertia
		inertia.append(3.0 / maxf(inv.x + inv.y + inv.z, 1e-9))
	for i in bodies.size():
		var floor_i := 0.0
		for k in bodies.size():
			if parent[k] == i or parent[i] == k:
				floor_i = maxf(floor_i, inertia[k] * MASS_CONDITIONING)
		var inv := state(i).inverse_inertia
		var own := Vector3(1.0 / maxf(inv.x, 1e-9), 1.0 / maxf(inv.y, 1e-9), 1.0 / maxf(inv.z, 1e-9))
		if own.x < floor_i or own.y < floor_i or own.z < floor_i:
			PhysicsServer3D.body_set_param(bodies[i].get_rid(), PhysicsServer3D.BODY_PARAM_INERTIA, Vector3(maxf(own.x, floor_i), maxf(own.y, floor_i), maxf(own.z, floor_i)))


# ------------------------------------------------------------------ queries

## The skeleton's animated local pose of bone b (outside the modifiers) on the clip skeleton's offsets.
func local_pose(b: int) -> Transform3D:
	var pos := skeleton.get_bone_pose_position(b) if animated_pos[b] else offsets[b]
	return Transform3D(Basis(skeleton.get_bone_pose_rotation(b)), pos)


## Skeleton-space transforms of every bone for the given local poses (index = bone), parents first.
func globals_of(locals: Array) -> Array[Transform3D]:
	var out: Array[Transform3D] = []
	out.resize(skeleton.get_bone_count())
	for b in out.size():
		var p := skeleton.get_bone_parent(b)
		out[b] = locals[b] if p < 0 else out[p] * (locals[b] as Transform3D)
	return out


## The animated pose on the clip skeleton's offsets, skeleton space, every bone.
func animated_globals() -> Array[Transform3D]:
	var locals := []
	for b in skeleton.get_bone_count():
		locals.append(local_pose(b))
	return globals_of(locals)


func state(i: int) -> PhysicsDirectBodyState3D:
	return PhysicsServer3D.body_get_direct_state(bodies[i].get_rid())


func body_transform(i: int) -> Transform3D:
	return state(i).transform


## World transform of the bone of body i (body transform without the body offset).
func bone_world(i: int) -> Transform3D:
	return state(i).transform * bodies[i].body_offset.affine_inverse()


func center_of_mass() -> Vector3:
	var c := Vector3.ZERO
	for i in bodies.size():
		c += state(i).transform.origin * mass[i]
	return c / total_mass


func set_gravity_scale(g: float) -> void:
	for b in bodies:
		PhysicsServer3D.body_set_param(b.get_rid(), PhysicsServer3D.BODY_PARAM_GRAVITY_SCALE, g)


## Fastest body (m/s), for explosion checks; 0 while the bodies don't simulate (a kinematic body's
## velocity is then just its per-frame placement).
func max_speed() -> float:
	if not simulating:
		return 0.0
	var v := 0.0
	for i in bodies.size():
		v = maxf(v, state(i).linear_velocity.length())
	return v


## Fastest spin (rad/s), diagnostics.
func max_spin() -> float:
	var v := 0.0
	for i in bodies.size():
		v = maxf(v, state(i).angular_velocity.length())
	return v


## Puts every body on the given bone world transforms, at rest (teleport).
func teleport(bone_world_targets: Array) -> void:
	for i in bodies.size():
		var rid := bodies[i].get_rid()
		var xf := (bone_world_targets[i] as Transform3D) * bodies[i].body_offset
		# The node too: a PhysicalBone3D sends its node transform to the server on its (deferred)
		# transform notification, which would undo this right after a start.
		bodies[i].global_transform = xf
		PhysicsServer3D.body_set_state(rid, PhysicsServer3D.BODY_STATE_TRANSFORM, xf)
		PhysicsServer3D.body_set_state(rid, PhysicsServer3D.BODY_STATE_LINEAR_VELOCITY, Vector3.ZERO)
		PhysicsServer3D.body_set_state(rid, PhysicsServer3D.BODY_STATE_ANGULAR_VELOCITY, Vector3.ZERO)
		_set_world_springs(i, false)  # their equilibria are still where the bodies were
	_prev_world.clear()
	_prev_local.clear()


# ------------------------------------------------------------------ controls

## One tick of the active profile's controls.
## world_targets: bone world transforms per body (the animated pose), or [] when there are no
## world-space targets; local_targets: bone-local rotations per body (relative to the parent bone);
## parent_mult: the four Ragdoll_Strength multipliers (head, torso, arms, legs) on the parent-space
## strength; extra_spin: body -> angular velocity change applied first (roll torque).
func drive(world_targets: Array, local_targets: Array, parent_mult: Vector4, dt: float, extra_spin := {}) -> void:
	if not simulating:
		return
	var n := bodies.size()
	var q: Array[Quaternion] = []
	var w: Array[Vector3] = []
	var pos: Array[Vector3] = []
	var inv_i: Array[Basis] = []
	for i in n:
		var s := state(i)
		q.append(s.transform.basis.get_rotation_quaternion())
		pos.append(s.transform.origin)
		w.append(s.angular_velocity + extra_spin.get(i, Vector3.ZERO))
		inv_i.append(s.inverse_inertia_tensor)

	# World-space controls.
	var world_on: bool = not world_targets.is_empty() and (params["world_lin"] > 0.0 or params["world_ang"] > 0.0)
	if world_on:
		var frames: Array[Transform3D] = []
		var far := 0.0
		for i in n:
			var f: Transform3D = (world_targets[i] as Transform3D) * bodies[i].body_offset
			frames.append(f)
			far = maxf(far, f.origin.distance_to(pos[i]))
		if far > TELEPORT_DISTANCE:
			teleport(world_targets)
			_prev_world = frames
			return
		var first := _prev_world.size() != n
		if not first:
			# bHasJustTeleported: the PCC drops the target velocities for a frame when the component jumps
			# (TeleportDistanceThreshold 300 cm). Placing the character by script (turning it in one tick)
			# is caught here too: the root body's target moving or turning faster than any animation does.
			var r := parent.find(-1)
			var rv := (frames[r].origin - (_prev_world[r] as Transform3D).origin).length() / dt
			var rw := _axis_angle(frames[r].basis.get_rotation_quaternion() * (_prev_world[r] as Transform3D).basis.get_rotation_quaternion().inverse()).length() / dt
			first = rv > JUMP_SPEED or rw > JUMP_TURN_RATE
		for i in n:
			var f := frames[i]
			var lin_s: float = params["feet_lin"] if is_foot[i] else params["world_lin"]
			var ang_s: float = params["feet_ang"] if is_foot[i] else params["world_ang"]
			var ratio: float = params["world_ratio"]
			var v_t := Vector3.ZERO
			var w_t := Vector3.ZERO
			if not first:
				var pf: Transform3D = _prev_world[i]
				v_t = (f.origin - pf.origin) / dt
				w_t = _axis_angle(f.basis.get_rotation_quaternion() * pf.basis.get_rotation_quaternion().inverse()) / dt
			_drive_world(i, f, v_t, w_t, lin_s, ang_s, ratio, q[i], inv_i[i])
		_prev_world = frames
	else:
		if not _prev_world.is_empty():
			for i in n:
				_set_world_springs(i, false)
		_prev_world.clear()

	# Parent-space controls (joint motors) and WidenLimits.
	var first_local := _prev_local.size() != n
	if first_local:
		_prev_local.resize(n)
	last_rel_target.resize(n)
	last_strength.resize(n)
	for i in n:
		if extra_spin.has(i):
			PhysicsServer3D.body_set_state(bodies[i].get_rid(), PhysicsServer3D.BODY_STATE_ANGULAR_VELOCITY, w[i])
		var p := parent[i]
		if p < 0 or not _joint_of.has(i):
			continue
		var rel_t: Quaternion = offset_rot[p].inverse() * (local_targets[i] as Quaternion) * offset_rot[i]
		var prev: Quaternion = rel_t if first_local or _prev_local[i] == null else _prev_local[i]
		_prev_local[i] = rel_t
		var strength: float = params["parent_ang"] * parent_mult[limb[i]]
		last_rel_target[i] = rel_t
		last_strength[i] = strength
		_widen_limits(i, rel_t, strength > 0.0)
		if strength <= 1e-4:
			_set_spring(i, false)
			continue
		# Chaos's angular drive (PhysInterface_Chaos UpdateAngularDrive): stiffness and damping x1.5
		# (p.Chaos.JointConstraint.AngularDriveStiffnessScale / DampingScale), acceleration mode: per
		# axis times the pair's effective inertia (InitRotationDatasMass), solved implicitly with the
		# joints. Here Jolt's 6DOF position motor (a soft constraint solved with the limits and
		# contacts), along the child's joint axes as Jolt drives them.
		var omega := TAU * strength
		var k := ANGULAR_DRIVE_STIFFNESS_SCALE * omega * omega
		var d := ANGULAR_DRIVE_DAMPING_SCALE * 2.0 * float(params["parent_ratio"]) * omega
		# The drive's velocity target (the target's own angular velocity, AngularTargetVelocityMultiplier
		# 1): k (x_t - x) + d (v_t - v) = k ((x_t + d/k v_t) - x) - d v, so the target leads by d/k v_t.
		var lead := (_axis_angle(rel_t * prev.inverse()) * (d / k / dt)).limit_length(MAX_LEAD)
		var rel_drive := rel_t
		if lead.length_squared() > 1e-12:
			rel_drive = Quaternion(lead.normalized(), lead.length()) * rel_t
		var axes := Basis(q[i]) * joint_child_frame[i].basis
		var inv_sum := Basis(inv_i[i].x + inv_i[p].x, inv_i[i].y + inv_i[p].y, inv_i[i].z + inv_i[p].z)
		var stiffness := Vector3.ZERO
		var damping := Vector3.ZERO
		for axis in 3:
			var a: Vector3 = axes[axis]
			var ii := a.dot(inv_sum * a)
			var m_eff := 1.0 / maxf(ii, 1e-9)
			stiffness[axis] = k * m_eff
			damping[axis] = d * m_eff
		_set_spring(i, true, _equilibrium(i, rel_drive), stiffness, damping)


## Turns body i's parent-space spring (the joint's angular position motor) on or off; equilibrium as
## Godot's 6DOF spring equilibrium angles, stiffness (N m/rad) and damping (N m s/rad) per joint axis.
func _set_spring(i: int, on: bool, equilibrium := Vector3.ZERO, stiffness := Vector3.ZERO, damping := Vector3.ZERO) -> void:
	var j: RID = _joint_of[i]
	for axis in 3:
		PhysicsServer3D.generic_6dof_joint_set_flag(j, axis, PhysicsServer3D.G6DOF_JOINT_FLAG_ENABLE_ANGULAR_SPRING, on)
		if not on:
			continue
		PhysicsServer3D.generic_6dof_joint_set_param(j, axis, PhysicsServer3D.G6DOF_JOINT_ANGULAR_SPRING_STIFFNESS, stiffness[axis])
		PhysicsServer3D.generic_6dof_joint_set_param(j, axis, PhysicsServer3D.G6DOF_JOINT_ANGULAR_SPRING_DAMPING, damping[axis])
		PhysicsServer3D.generic_6dof_joint_set_param(j, axis, PhysicsServer3D.G6DOF_JOINT_ANGULAR_SPRING_EQUILIBRIUM_POINT, equilibrium[axis])


## Spring equilibrium for a child-body-relative-to-parent-body rotation. Jolt drives the joint's
## rotation in constraint space (child frame relative to parent frame) to
## Basis.from_euler(-equilibrium, ZYX) (JoltGeneric6DOFJoint3D::_update_spring_equilibrium).
func _equilibrium(i: int, rel: Quaternion) -> Vector3:
	var fp := joint_parent_frame[i].basis.get_rotation_quaternion()
	var fc := joint_child_frame[i].basis.get_rotation_quaternion()
	return -Basis(fp.inverse() * rel * fc).get_euler(EULER_ORDER_ZYX)


## World-space control of body i (a PCC control with no parent: a drive between the body's centre
## of mass and the world): the body frame f with velocity v_t, w_t; strengths in Hz. Linear drives are
## used as is (LinearDriveStiffnessScale 1), angular ones x1.5; both in acceleration mode (times the
## body's mass / its inertia about each world axis). The velocity targets lead the targets by d/k.
func _drive_world(i: int, f: Transform3D, v_t: Vector3, w_t: Vector3, lin_s: float, ang_s: float, ratio: float, q: Quaternion, inv_inertia: Basis) -> void:
	var j: RID = _world_joint[i]
	var r1 := Basis(q)
	var lin_on := lin_s > 0.0
	var ang_on := ang_s > 0.0
	for axis in 3:
		PhysicsServer3D.generic_6dof_joint_set_flag(j, axis, PhysicsServer3D.G6DOF_JOINT_FLAG_ENABLE_LINEAR_SPRING, lin_on)
		PhysicsServer3D.generic_6dof_joint_set_flag(j, axis, PhysicsServer3D.G6DOF_JOINT_FLAG_ENABLE_ANGULAR_SPRING, ang_on)
	if lin_on:
		var omega := TAU * lin_s
		var k := LINEAR_DRIVE_STIFFNESS_SCALE * omega * omega
		var d := LINEAR_DRIVE_DAMPING_SCALE * 2.0 * ratio * omega
		# With no body B Godot makes the world Jolt's body 1, so the joint drives the body's centre of
		# mass to the equilibrium in world coordinates along the world axes (measured).
		var target := f.origin + v_t * (d / k)
		var m := mass[i]
		for axis in 3:
			PhysicsServer3D.generic_6dof_joint_set_param(j, axis, PhysicsServer3D.G6DOF_JOINT_LINEAR_SPRING_STIFFNESS, k * m)
			PhysicsServer3D.generic_6dof_joint_set_param(j, axis, PhysicsServer3D.G6DOF_JOINT_LINEAR_SPRING_DAMPING, d * m)
			PhysicsServer3D.generic_6dof_joint_set_param(j, axis, PhysicsServer3D.G6DOF_JOINT_LINEAR_SPRING_EQUILIBRIUM_POINT, target[axis])
	if ang_on:
		var omega := TAU * ang_s
		var k := ANGULAR_DRIVE_STIFFNESS_SCALE * omega * omega
		var d := ANGULAR_DRIVE_DAMPING_SCALE * 2.0 * ratio * omega
		var qt := f.basis.get_rotation_quaternion()
		var lead := (w_t * (d / k)).limit_length(MAX_LEAD)
		if lead.length_squared() > 1e-12:
			qt = Quaternion(lead.normalized(), lead.length()) * qt
		# The constraint rotation is the body's world rotation; Jolt drives it about the body's axes.
		var eq := -Basis(qt).get_euler(EULER_ORDER_ZYX)
		for axis in 3:
			var a: Vector3 = r1[axis]
			var m_eff := 1.0 / maxf(a.dot(inv_inertia * a), 1e-9)
			PhysicsServer3D.generic_6dof_joint_set_param(j, axis, PhysicsServer3D.G6DOF_JOINT_ANGULAR_SPRING_STIFFNESS, k * m_eff)
			PhysicsServer3D.generic_6dof_joint_set_param(j, axis, PhysicsServer3D.G6DOF_JOINT_ANGULAR_SPRING_DAMPING, d * m_eff)
			PhysicsServer3D.generic_6dof_joint_set_param(j, axis, PhysicsServer3D.G6DOF_JOINT_ANGULAR_SPRING_EQUILIBRIUM_POINT, eq[axis])


func _set_world_springs(i: int, on: bool) -> void:
	if i >= _world_joint.size():
		return
	for axis in 3:
		PhysicsServer3D.generic_6dof_joint_set_flag(_world_joint[i], axis, PhysicsServer3D.G6DOF_JOINT_FLAG_ENABLE_LINEAR_SPRING, on)
		PhysicsServer3D.generic_6dof_joint_set_flag(_world_joint[i], axis, PhysicsServer3D.G6DOF_JOINT_FLAG_ENABLE_ANGULAR_SPRING, on)


## Joint angles (twist, swing about Y, swing about Z) of a child-relative-to-parent body rotation.
func joint_angles(i: int, rel: Quaternion) -> Vector3:
	var fp := joint_parent_frame[i].basis.get_rotation_quaternion()
	var fc := joint_child_frame[i].basis.get_rotation_quaternion()
	var j := fp.inverse() * rel * fc
	if j.w < 0.0:
		j = -j
	var twist := Quaternion(j.x, 0.0, 0.0, j.w).normalized()
	var swing := j * twist.inverse()
	var x := swing * Vector3.RIGHT
	return Vector3(wrapf(2.0 * atan2(twist.x, twist.w), -PI, PI), atan2(-x.z, x.x), atan2(x.y, x.x))


## WidenLimits: limits that a drive target lies past open to the target + 0.5 deg; back to the
## asset's when not driven.
func _widen_limits(i: int, rel_t: Quaternion, driven: bool) -> void:
	var lim := joint_limits[i]
	if driven:
		var a := joint_angles(i, rel_t).abs()
		var m := deg_to_rad(WIDEN_MARGIN)
		lim = Vector3(maxf(lim.x, a.x + m if a.x > lim.x else lim.x), maxf(lim.y, a.y + m if a.y > lim.y else lim.y), maxf(lim.z, a.z + m if a.z > lim.z else lim.z))
	_set_limits(i, lim)


## Angle (rad) between body i's rotation relative to its parent body now and its last parent-space
## target; -1 when it has none.
func bend_error(i: int) -> float:
	var p := parent[i]
	if p < 0 or i >= last_rel_target.size() or last_rel_target[i] == null:
		return -1.0
	var rel := state(p).transform.basis.get_rotation_quaternion().inverse() * state(i).transform.basis.get_rotation_quaternion()
	return _axis_angle((last_rel_target[i] as Quaternion).inverse() * rel).length()


static func _axis_angle(r: Quaternion) -> Vector3:
	if r.w < 0.0:
		r = -r
	var v := Vector3(r.x, r.y, r.z)
	var s := v.length()
	if s < 1e-7:
		return v * 2.0
	return v / s * (2.0 * atan2(s, r.w))


## Largest overshoot of the joint limits now (as widened), degrees (twist about X, swing against the
## elliptical bound in its direction).
func max_limit_violation() -> float:
	var worst := 0.0
	for i in bodies.size():
		var p := parent[i]
		if p < 0:
			continue
		var fp := state(p).transform * joint_parent_frame[i]
		var fc := state(i).transform * joint_child_frame[i]
		var rel := (fp.basis.orthonormalized().inverse() * fc.basis.orthonormalized()).get_rotation_quaternion()
		var twist := wrapf(2.0 * atan2(rel.x, rel.w), -PI, PI)
		var x := rel * Vector3.RIGHT
		var lim := joint_set_limits[i] if _joint_of.has(i) else joint_limits[i]
		var swing := acos(clampf(x.x, -1.0, 1.0))
		var phi := atan2(x.y, -x.z)
		var bound := 1.0 / sqrt(pow(cos(phi) / maxf(lim.y, 1e-3), 2.0) + pow(sin(phi) / maxf(lim.z, 1e-3), 2.0))
		var over := maxf(absf(twist) - lim.x, swing - bound)
		if over > worst:
			worst = over
			worst_joint = "%s tw %.0f swing %.0f (limit %.0f)" % [names[i], rad_to_deg(twist), rad_to_deg(swing), rad_to_deg(bound)]
	return rad_to_deg(worst)
