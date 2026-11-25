// Exact pose search over one PoseDatabase (scripts/motion/pose_database.gd), with Unreal's cost:
//   cost = sum_i (stored_i - query_i * weight_i)^2 + pose addend (+ continuing bias for the continuing pose)
// Stored values are already weighted. Poses are grouped in blocks; a block is skipped when the
// distance from the query to its bounding box plus its smallest addend can't beat the best so far,
// so the result is the same as checking every pose (Unreal's PCA/KD-tree search is approximate).
#pragma once

#include <godot_cpp/classes/ref_counted.hpp>
#include <godot_cpp/variant/packed_byte_array.hpp>
#include <godot_cpp/variant/packed_float32_array.hpp>
#include <godot_cpp/variant/packed_int32_array.hpp>

#include <vector>

namespace godot {

class PoseSearch : public RefCounted {
	GDCLASS(PoseSearch, RefCounted)

public:
	void set_database(const PackedFloat32Array &p_values, int p_dims, const PackedFloat32Array &p_weights,
			const PackedFloat32Array &p_addend, const PackedByteArray &p_blocked, const PackedInt32Array &p_pose_entry);
	// Weights a raw query (multiplies by the database's weights).
	PackedFloat32Array weigh(const PackedFloat32Array &p_raw_query) const;
	// Best pose for a weighted query. Excluded poses and every pose of an excluded entry are skipped,
	// as are poses with a block-transition notify. Only poses that beat p_best_cost count.
	// Returns [pose, cost], pose -1 when nothing beat p_best_cost.
	PackedFloat32Array search(const PackedFloat32Array &p_query, const PackedInt32Array &p_excluded_poses,
			const PackedInt32Array &p_excluded_entries, float p_best_cost) const;
	// Feature cost of one pose (no addend).
	float feature_cost(int p_pose, const PackedFloat32Array &p_query) const;
	int pose_count() const { return poses; }

protected:
	static void _bind_methods();

private:
	static constexpr int BLOCK = 16;
	std::vector<float> values;
	std::vector<float> weights;
	std::vector<float> addend;
	std::vector<uint8_t> blocked;
	std::vector<int> pose_entry;
	std::vector<float> block_min;
	std::vector<float> block_max;
	std::vector<float> block_min_addend;
	int dims = 0;
	int poses = 0;
};

} // namespace godot
