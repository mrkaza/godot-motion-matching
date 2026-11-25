extends SkeletonModifier3D
## The Mover ABP's Procedural_PreLayering: while Sliding (BlendListByEnum on MovementMode, 0.3 s
## blends) a ModifyBone on root, both additive:
## - Rotation (component space) = Get_SlideSlopeRotation: MakeRotator(-SlopeAngle.Y, -SlopeAngle.X, 0),
##   SlopeAngle = GetSlopeDegreeAngles(RootTransform's right, SmoothedGroundNormal, actor up) as
##   (roll, pitch). The body leans with the ground: its forward and right take the ground's slope.
## - Translation (world space) = Get_SlideSlopeOffset: ProjectPointOnToPlane(root, GroundLocation,
##   SmoothedGroundNormal) - root, the root moved onto the ground plane.
## SmoothedGroundNormal = VInterpTo(it, GroundNormal, dt, 5) every anim update (Update_EssentialValues);
## GroundLocation / GroundNormal are the pawn's floor hit (Update_FloorValues).
## MotionMatcher sets the inputs and calls update() every physics frame.

const BLEND_TIME := 0.3
const NORMAL_INTERP_SPEED := 5.0
const SKELETON_FORWARD := Vector3(0, -1, 0)  # the root's facing in skeleton space (Unreal's component Y)

var sliding := false
var ground_normal := Vector3.UP
var ground_point := Vector3.ZERO
var smoothed_normal := Vector3.UP
## The Sliding pose's weight in the blend list.
var weight := 0.0
var _root := -1


func update(dt: float) -> void:
	smoothed_normal = _vinterp_to(smoothed_normal, ground_normal, dt, NORMAL_INTERP_SPEED)
	weight = move_toward(weight, 1.0 if sliding else 0.0, dt / BLEND_TIME)


func _process_modification_with_delta(_delta: float) -> void:
	if weight <= 0.0:
		return
	var sk := get_skeleton()
	if _root < 0:
		_root = sk.find_bone("root")
	var g := sk.global_transform
	var w := g * sk.get_bone_global_pose(_root)
	var f := w.basis * SKELETON_FORWARD
	f = Vector3(f.x, 0, f.z).normalized()
	var r := f.cross(Vector3.UP)  # the root's right
	var n := smoothed_normal
	# GetSlopeDegreeAngles (Unreal's crosses are the other way round in its left-handed axes).
	var floor_x := n.cross(r)
	var floor_y := floor_x.cross(n)
	var pitch := PI * 0.5 - acos(clampf(floor_x.dot(Vector3.UP), -1.0, 1.0))
	var roll := PI * 0.5 - acos(clampf(floor_y.dot(Vector3.UP), -1.0, 1.0))
	# Forward takes the ground's pitch, right its roll (FRotator: roll applied first, then pitch).
	var q := Quaternion(f, -roll) * Quaternion(r, pitch)
	q = Quaternion.IDENTITY.slerp(q, weight)
	var offset := -((w.origin - ground_point).dot(n)) * n * weight
	var out := Transform3D(Basis(q) * w.basis, w.origin + offset)
	sk.set_bone_global_pose(_root, g.affine_inverse() * out)


static func _vinterp_to(current: Vector3, target: Vector3, dt: float, speed: float) -> Vector3:
	if speed <= 0.0:
		return target
	var dist := target - current
	if dist.length_squared() < 1e-4:  # UE_KINDA_SMALL_NUMBER
		return target
	return current + dist * clampf(dt * speed, 0.0, 1.0)
