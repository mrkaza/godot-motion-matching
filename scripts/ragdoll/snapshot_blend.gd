# Pose snapshot "Ragdoll" for the get-up blend: holds the last
# physics pose as local bone poses and writes it over the animation. The ragdoll component lowers
# `influence` from 1 to 0 along the get-up montage's blend-in, so the skin goes from the physics pose
# into the get-up clip the way the montage blends in over the snapshot in Unreal.
extends SkeletonModifier3D

## Local pose per bone index; empty = nothing to write.
var poses: Array[Transform3D] = []


func _process_modification_with_delta(_delta: float) -> void:
	var sk := get_skeleton()
	if sk == null or poses.size() != sk.get_bone_count():
		return
	for i in poses.size():
		sk.set_bone_pose(i, poses[i])
