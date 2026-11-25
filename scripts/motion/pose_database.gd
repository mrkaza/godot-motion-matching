# One pose search database, built from the Game Animation Sample by tools/bake/bake_databases.gd.
# Mirrors Unreal's UPoseSearchDatabase after indexing: one feature vector per sampled pose, stored
# already multiplied by the per-dimension weights, so cost = sum((stored - query * weights)^2) + addends.
class_name PoseDatabase
extends Resource

@export var db_name: String
@export var db_path: String
@export var schema_name: String
@export var sample_rate: float = 30.0
@export var dims: int
## sqrt(w / sum w) / deviation per dimension (Unreal's WeightsSqrt).
@export var weights: PackedFloat32Array
## Leaves of the schema in order (type, offset, cardinality, bones, time offsets, flags).
## Used to build the query the same way the features were built.
@export var leaves: Array[Dictionary]
@export var continuing_pose_cost_bias: float = -0.01

# Entries (one per database asset).
@export var entry_clip: PackedStringArray       ## res:// path of the clip's AnimationLibrary
@export var entry_loops: PackedByteArray
@export var entry_disable_reselection: PackedByteArray
@export var entry_length: PackedFloat32Array

# Poses.
@export var pose_entry: PackedInt32Array
@export var pose_time: PackedFloat32Array
## Cost addend per pose, rounded to half float as Unreal stores it.
@export var pose_addend: PackedFloat32Array
@export var pose_blocked: PackedByteArray
## Continuing pose cost bias override from notifies, NAN where none.
@export var pose_continuing_bias: PackedFloat32Array
## Weighted features, dims floats per pose.
@export var values: PackedFloat32Array


func pose_count() -> int:
	return pose_entry.size()


## Pose index for an entry at a time (Unreal's GetPoseIndex: round to the sample, wrap when looping).
func pose_index(entry: int, time: float) -> int:
	var first := pose_entry.find(entry)
	if first < 0:
		return -1
	var last := pose_entry.rfind(entry)
	var t0 := pose_time[first]
	var index := roundi((time - t0) * sample_rate)
	var count := last - first + 1
	if entry_loops[entry]:
		index = posmod(index, count)
	elif index < 0 or index >= count:
		return -1
	return first + index


## Unweighted feature value (what Unreal stores), for query channels that copy the continuing pose.
func raw_value(pose: int, dim: int) -> float:
	var w := weights[dim]
	return values[pose * dims + dim] / w if w != 0.0 else 0.0
