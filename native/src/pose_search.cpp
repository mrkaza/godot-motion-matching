#include "pose_search.h"

#include <godot_cpp/core/class_db.hpp>

#include <algorithm>
#include <limits>

using namespace godot;

void PoseSearch::set_database(const PackedFloat32Array &p_values, int p_dims, const PackedFloat32Array &p_weights,
		const PackedFloat32Array &p_addend, const PackedByteArray &p_blocked, const PackedInt32Array &p_pose_entry) {
	dims = p_dims;
	poses = dims > 0 ? (int)(p_values.size() / dims) : 0;
	values.assign(p_values.ptr(), p_values.ptr() + p_values.size());
	weights.assign(p_weights.ptr(), p_weights.ptr() + p_weights.size());
	addend.assign(p_addend.ptr(), p_addend.ptr() + p_addend.size());
	blocked.assign(p_blocked.ptr(), p_blocked.ptr() + p_blocked.size());
	pose_entry.assign(p_pose_entry.ptr(), p_pose_entry.ptr() + p_pose_entry.size());
	const int blocks = (poses + BLOCK - 1) / BLOCK;
	block_min.assign((size_t)blocks * dims, std::numeric_limits<float>::max());
	block_max.assign((size_t)blocks * dims, -std::numeric_limits<float>::max());
	block_min_addend.assign(blocks, std::numeric_limits<float>::max());
	for (int p = 0; p < poses; ++p) {
		const int b = p / BLOCK;
		const float *row = &values[(size_t)p * dims];
		for (int d = 0; d < dims; ++d) {
			block_min[(size_t)b * dims + d] = std::min(block_min[(size_t)b * dims + d], row[d]);
			block_max[(size_t)b * dims + d] = std::max(block_max[(size_t)b * dims + d], row[d]);
		}
		block_min_addend[b] = std::min(block_min_addend[b], addend[p]);
	}
}

PackedFloat32Array PoseSearch::weigh(const PackedFloat32Array &p_raw_query) const {
	PackedFloat32Array result;
	result.resize(dims);
	for (int d = 0; d < dims && d < p_raw_query.size(); ++d) {
		result.set(d, p_raw_query[d] * weights[d]);
	}
	return result;
}

float PoseSearch::feature_cost(int p_pose, const PackedFloat32Array &p_query) const {
	if (p_pose < 0 || p_pose >= poses || p_query.size() < dims) {
		return std::numeric_limits<float>::max();
	}
	const float *row = &values[(size_t)p_pose * dims];
	const float *q = p_query.ptr();
	float total = 0.0f;
	for (int d = 0; d < dims; ++d) {
		const float diff = row[d] - q[d];
		total += diff * diff;
	}
	return total;
}

PackedFloat32Array PoseSearch::search(const PackedFloat32Array &p_query, const PackedInt32Array &p_excluded_poses,
		const PackedInt32Array &p_excluded_entries, float p_best_cost) const {
	PackedFloat32Array result;
	result.resize(2);
	result.set(0, -1.0f);
	result.set(1, p_best_cost);
	if (p_query.size() < dims) {
		return result;
	}
	const float *q = p_query.ptr();
	std::vector<uint8_t> excluded_entry;
	for (int i = 0; i < p_excluded_entries.size(); ++i) {
		const int e = p_excluded_entries[i];
		if (e >= (int)excluded_entry.size()) {
			excluded_entry.resize(e + 1, 0);
		}
		excluded_entry[e] = 1;
	}
	std::vector<int> excluded(p_excluded_poses.ptr(), p_excluded_poses.ptr() + p_excluded_poses.size());
	std::sort(excluded.begin(), excluded.end());

	float best = p_best_cost;
	int best_pose = -1;
	const int blocks = (poses + BLOCK - 1) / BLOCK;
	for (int b = 0; b < blocks; ++b) {
		// Lower bound of every pose's cost in this block.
		float bound = block_min_addend[b];
		const float *mn = &block_min[(size_t)b * dims];
		const float *mx = &block_max[(size_t)b * dims];
		for (int d = 0; d < dims && bound < best; ++d) {
			const float below = mn[d] - q[d];
			const float above = q[d] - mx[d];
			const float gap = below > 0.0f ? below : (above > 0.0f ? above : 0.0f);
			bound += gap * gap;
		}
		if (bound >= best) {
			continue;
		}
		const int end = std::min(poses, (b + 1) * BLOCK);
		for (int p = b * BLOCK; p < end; ++p) {
			if (blocked[p]) {
				continue;
			}
			const int e = pose_entry[p];
			if (e < (int)excluded_entry.size() && excluded_entry[e]) {
				continue;
			}
			float total = addend[p];
			const float *row = &values[(size_t)p * dims];
			for (int d = 0; d < dims && total < best; ++d) {
				const float diff = row[d] - q[d];
				total += diff * diff;
			}
			if (total < best && !std::binary_search(excluded.begin(), excluded.end(), p)) {
				best = total;
				best_pose = p;
			}
		}
	}
	result.set(0, (float)best_pose);
	result.set(1, best);
	return result;
}

void PoseSearch::_bind_methods() {
	ClassDB::bind_method(D_METHOD("set_database", "values", "dims", "weights", "addend", "blocked", "pose_entry"), &PoseSearch::set_database);
	ClassDB::bind_method(D_METHOD("weigh", "raw_query"), &PoseSearch::weigh);
	ClassDB::bind_method(D_METHOD("search", "query", "excluded_poses", "excluded_entries", "best_cost"), &PoseSearch::search);
	ClassDB::bind_method(D_METHOD("feature_cost", "pose", "query"), &PoseSearch::feature_cost);
	ClassDB::bind_method(D_METHOD("pose_count"), &PoseSearch::pose_count);
}
