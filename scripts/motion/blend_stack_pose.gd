extends SkeletonModifier3D
## The parts of the motion matching blend stack's pose that Godot's AnimationTree blend can't do
## (MotionMatcher sets the inputs every physics frame):
## - Blend profile FastFeet+Root_Weight (the MM node's BlendProfile, WeightFactor mode,
##   extracted/data/blend_profile_FastFeet_Root_Weight.t3d): a bone with scale s blends in over
##   BlendTime / s (UBlendProfile::FillSkeletonBoneDurationsArray). The legs and ik feet (1.5) are
##   re-blended here from the players' clips like FAnimNode_BlendStack::BlendWithPosePerBone; the
##   root (10) only carries root motion, which MotionMatcher blends with the root's weights.
## - Orientation warping (OrientationWarping_1, AnimNode_OrientationWarping.cpp) with
##   DistributedBoneOrientationAlpha 0.5: root turns by half the angle, spine_01..05 turn it back
##   (a fifth each), ik_foot_root turns by the other half and the ik feet keep the root's turn.
##   Each angle is the players' angles blended with that bone's blend weights.

const PROFILE := {"ik_foot_root": 1.5, "ik_foot_l": 1.5, "ik_foot_r": 1.5,
	"thigh_l": 1.5, "calf_l": 1.5, "calf_twist_01_l": 1.5, "calf_twist_02_l": 1.5, "foot_l": 1.5, "ball_l": 1.5, "thigh_twist_01_l": 1.5,
	"thigh_r": 1.5, "calf_r": 1.5, "calf_twist_01_r": 1.5, "calf_twist_02_r": 1.5, "foot_r": 1.5, "ball_r": 1.5, "thigh_twist_01_r": 1.5}
const ROOT_SCALE := 10.0
const DISTRIBUTED_BONE_ORIENTATION_ALPHA := 0.5
const SPINE := ["spine_01", "spine_02", "spine_03", "spine_04", "spine_05"]
const UP := Vector3(0, 0, 1)  # skeleton-space up (Unreal's component Z)

## The animation tree playing the clips.
var tree: AnimationTree
## [animation name, time, blend-in time, blend time, profiled] per blend-stack player, newest first.
## A player blends with the profile only when "profiled": blends to or from a traversal / get-up
## clip are the montage slot's blends in Unreal, which use no profile.
var players: Array = []
## Orientation warping angles (radians about up) blended with the root's, the spine's (default)
## and the feet's (profile 1.5) blend weights.
var root_angle := 0.0
var spine_angle := 0.0
var foot_angle := 0.0

var _bones := {}
var _tracks := {}  # animation name -> {bone: [rotation track, position track]}


## Per-player weights for a bone whose blend time is the player's blend time / `scale` (newest
## first; the oldest takes what is left), HermiteCubic like the stack. Players that aren't
## "profiled" use their plain blend time.
static func weights(stack: Array, scale: float) -> PackedFloat32Array:
	var w := PackedFloat32Array()
	w.resize(stack.size())
	var remaining := 1.0
	for i in stack.size():
		var x := 1.0
		var total: float = float(stack[i][3]) / (scale if stack[i][4] else 1.0)
		if i < stack.size() - 1 and total > 1e-8:
			x = clampf(float(stack[i][2]) / total, 0.0, 1.0)
			x = x * x * (3.0 - 2.0 * x)
		w[i] = remaining * x
		remaining *= 1.0 - x
	return w


func _process_modification_with_delta(_delta: float) -> void:
	var sk := get_skeleton()
	if _bones.is_empty():
		for n: String in PROFILE.keys() + SPINE + ["root"]:
			_bones[n] = sk.find_bone(n)
	if players.size() > 1 and tree != null:
		_reblend(sk)
	if not is_zero_approx(root_angle) or not is_zero_approx(spine_angle) or not is_zero_approx(foot_angle):
		_warp(sk)


func _reblend(sk: Skeleton3D) -> void:
	var w := weights(players, 1.5)
	for bone: String in PROFILE:
		var b: int = _bones[bone]
		if b < 0:
			continue
		var rot := Quaternion(0, 0, 0, 0)
		var pos := Vector3.ZERO
		var has_pos := false
		var first := true
		for i in players.size():
			if w[i] <= 0.0:
				continue
			var anim := tree.get_animation(players[i][0])
			if anim == null:
				continue
			var tr: Array = _track(anim, players[i][0], bone)
			var t: float = players[i][1]
			var q := anim.rotation_track_interpolate(tr[0], t) if tr[0] >= 0 else sk.get_bone_pose_rotation(b)
			if not first and rot.dot(q) < 0.0:
				q = -q
			rot += q * w[i]
			first = false
			if tr[1] >= 0:
				pos += anim.position_track_interpolate(tr[1], t) * w[i]
				has_pos = true
		if first:
			continue
		sk.set_bone_pose_rotation(b, rot.normalized())
		if has_pos:
			sk.set_bone_pose_position(b, pos)


func _track(anim: Animation, anim_name: StringName, bone: String) -> Array:
	var per: Dictionary = _tracks.get(anim_name, {})
	if not per.has(bone):
		var path := NodePath("Skeleton3D:" + bone)
		per[bone] = [anim.find_track(path, Animation.TYPE_ROTATION_3D), anim.find_track(path, Animation.TYPE_POSITION_3D)]
		_tracks[anim_name] = per
	return per[bone]


func _warp(sk: Skeleton3D) -> void:
	var a := DISTRIBUTED_BONE_ORIENTATION_ALPHA
	_turn(sk, "root", wrapf(root_angle * a, -PI, PI))
	for n: String in SPINE:
		_turn(sk, n, -spine_angle * a / SPINE.size())
	_turn(sk, "ik_foot_root", foot_angle * (1.0 - a))
	for n: String in ["ik_foot_l", "ik_foot_r"]:
		_turn(sk, n, -foot_angle * (1.0 - a))


## Rotates a bone in skeleton space about up through its own position; children follow.
func _turn(sk: Skeleton3D, bone: String, angle: float) -> void:
	var b: int = _bones.get(bone, -1)
	if b < 0:
		return
	var g := sk.get_bone_global_pose(b)
	g.basis = Basis(UP, angle) * g.basis
	sk.set_bone_global_pose(b, g)
