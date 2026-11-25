# Unreal's AnimNode_LegIK (AnimGraphRuntime/Private/BoneControllers/AnimNode_LegIK.cpp, UE 5.8) for a
# two-bone leg, as the sample's SandboxCharacter_Mover_ABP uses it in Procedural_Feet ("BasicIK"):
# LegsDefinition (ik_foot_l -> foot_l, ik_foot_r -> foot_r, HingeRotationAxis Z, bEnableRotationLimit),
# SoftPercentLength 0.99, SoftAlpha 1, knee twist correction on (FAnimLegIKDefinition default) with
# FootBoneForwardAxis Y. All math in Unreal component space (cm), on transforms in the skeleton's
# bone frames converted by UeSpace.
extends RefCounted

const SOFT_PERCENT_LENGTH := 0.99
const SOFT_ALPHA := 1.0
const KINDA_SMALL := 1e-4

## FIKChainLink::RealBendDir / BaseBendDir of the knee, kept between frames (per leg).
var real_bend_dir := Vector3.ZERO
var base_bend_dir := Vector3.ZERO


## FQuat::FindBetweenNormals (UnrealMath.cpp FindBetween_Helper with NormAB 1), on the vectors as given.
static func find_between(a: Vector3, b: Vector3) -> Quaternion:
	return _find_between(a, b, 1.0)


## FQuat::FindBetweenVectors.
static func find_between_vectors(a: Vector3, b: Vector3) -> Quaternion:
	return _find_between(a, b, sqrt(a.length_squared() * b.length_squared()))


static func _find_between(a: Vector3, b: Vector3, norm_ab: float) -> Quaternion:
	var w := norm_ab + a.dot(b)
	var q: Quaternion
	if w >= 1e-6 * norm_ab:
		q = Quaternion(a.y * b.z - a.z * b.y, a.z * b.x - a.x * b.z, a.x * b.y - a.y * b.x, w)
	else:
		var basis := Vector3(0, 1, 0) if (absf(a.x) > absf(a.y) and absf(a.x) > absf(a.z)) else Vector3(-1, 0, 0)
		q = Quaternion(a.y * basis.z - a.z * basis.y, a.z * basis.x - a.x * basis.z, a.x * basis.y - a.y * basis.x, 0.0)
	var l := q.length()
	return q / l if l > 1e-8 else Quaternion.IDENTITY


static func safe_normal(v: Vector3) -> Vector3:
	var l := v.length_squared()
	if l < 1e-8:
		return Vector3.ZERO
	return v / sqrt(l)


## AnimationCore::SoftenIKEffectorPosition.
static func soften(root: Vector3, total: float, soft_percent: float, alpha: float, effector: Vector3) -> Vector3:
	if absf(1.0 - soft_percent) < KINDA_SMALL or total <= KINDA_SMALL:
		return effector
	var to := effector - root
	var cur := to.length()
	var dir := to / cur if cur > 1e-8 else Vector3.ZERO
	var soft_distance := total * (1.0 - minf(1.0, soft_percent))
	var hard := total - soft_distance
	var delta := cur - hard
	if delta <= KINDA_SMALL or soft_distance <= KINDA_SMALL:
		return effector
	var softened := hard + soft_distance * (1.0 - exp(-delta / soft_distance))
	var a := clampf(alpha, 0.0, 1.0)
	if a < 1.0:
		return root + dir * lerpf(minf(cur, total), softened, alpha)
	return root + dir * softened


## Rotates every transform of the leg (foot, calf, thigh; [0] = foot) about the hip by q.
static func _rotate_leg(q: Quaternion, leg: Array) -> bool:
	if q.is_equal_approx(Quaternion.IDENTITY):
		return false
	var hip: Vector3 = (leg[2] as Transform3D).origin
	for i in leg.size():
		var t: Transform3D = leg[i]
		leg[i] = Transform3D(Basis(q) * t.basis, hip + q * (t.origin - hip))
	return true


static func _rotate_by_normals(from: Vector3, to: Vector3, leg: Array) -> bool:
	if from == Vector3.ZERO or from.is_equal_approx(to):
		return false
	return _rotate_leg(find_between(from, to), leg)


## One leg. leg: component-space transforms [foot, calf, thigh] (modified in place); ik_foot: the
## component-space IK foot target. Returns true if the leg changed.
func solve(leg: Array, ik_foot: Transform3D) -> bool:
	var hip: Vector3 = (leg[2] as Transform3D).origin
	# OrientLegTowardsIK.
	var oriented := _rotate_by_normals(safe_normal((leg[0] as Transform3D).origin - hip), safe_normal(ik_foot.origin - hip), leg)
	# DoLegReachIK (the solver always runs: rotation limit and soft IK are on).
	var links := [(leg[0] as Transform3D).origin, (leg[1] as Transform3D).origin, (leg[2] as Transform3D).origin]
	var len_lower: float = links[0].distance_to(links[1])
	var len_upper: float = links[1].distance_to(links[2])
	var total := len_lower + len_upper
	var hinge := ((leg[2] as Transform3D).basis * Vector3(0, 0, 1)).normalized()  # thigh's Z (GetUnitAxis Z)
	var root: Vector3 = links[2]
	var target := soften(root, total, SOFT_PERCENT_LENGTH, SOFT_ALPHA, ik_foot.origin)
	# ReachTarget: three links -> SolveTwoBoneIK on the softened target (soft IK is on, so it is used
	# whether or not the target is reachable).
	_two_bone(links, target, len_upper, len_lower, hinge)
	# Rotations from the links, root first.
	for li in [1, 0]:
		var parent_t: Transform3D = leg[li + 1]
		var cur_t: Transform3D = leg[li]
		var initial := safe_normal(cur_t.origin - parent_t.origin)
		var target_dir := safe_normal((links[li] as Vector3) - (links[li + 1] as Vector3))
		leg[li + 1] = Transform3D(Basis(find_between(initial, target_dir)) * parent_t.basis, parent_t.origin)
	for li in [1, 0]:
		var t: Transform3D = leg[li]
		leg[li] = Transform3D(t.basis, links[li])
	# AdjustKneeTwist (FootBoneForwardAxis Y).
	var foot_z := safe_normal(ik_foot.origin - (leg[2] as Transform3D).origin)
	var fk_x := ((leg[0] as Transform3D).basis * Vector3(0, 1, 0)).normalized()
	var ik_x := (ik_foot.basis * Vector3(0, 1, 0)).normalized()
	fk_x = foot_z.cross(fk_x).cross(foot_z)
	ik_x = foot_z.cross(ik_x).cross(foot_z)
	_rotate_by_normals(fk_x, ik_x, leg)
	# Foot FK rotation = IK foot rotation.
	var f: Transform3D = leg[0]
	leg[0] = Transform3D(Basis(ik_foot.basis.get_rotation_quaternion()), f.origin)
	return true or oriented


## FIKChain::SolveTwoBoneIK. links: [foot, knee, hip] locations, modified in place.
func _two_bone(links: Array, target: Vector3, a: float, c: float, hinge: Vector3) -> void:
	links[0] = target
	var pC: Vector3 = links[2]
	var pB: Vector3 = links[1]
	var hip_to_foot: Vector3 = target - pC
	var b := hip_to_foot.length()
	var two_ab := 2.0 * a * b
	var cos_c := (a * a + b * b - c * c) / two_ab if absf(two_ab) > 1e-8 else 0.0
	var angle_c := acos(clampf(cos_c, -1.0, 1.0))  # the soft target keeps it in range; Unreal does not clamp
	var dir: Vector3 = hip_to_foot / b if absf(b) > 1e-8 else Vector3.ZERO
	var hip_to_knee := pB - pC
	var proj_knee := pC + dir * hip_to_knee.dot(dir)
	var bend := (pB - proj_knee)
	bend = bend.normalized() if bend.length() > KINDA_SMALL else Vector3.ZERO
	if hinge != Vector3.ZERO and dir != Vector3.ZERO and absf(a) > 1e-8:
		var knee_dot := (hip_to_knee / a).dot(dir)
		if bend != Vector3.ZERO and knee_dot < 0.99:
			real_bend_dir = bend
			base_bend_dir = hinge.cross(dir)
		elif real_bend_dir != Vector3.ZERO:
			var cur_base := hinge.cross(dir)
			bend = find_between(base_bend_dir, cur_base) * real_bend_dir
	links[1] = pC + a * (dir * cos(angle_c) + bend * sin(angle_c))
