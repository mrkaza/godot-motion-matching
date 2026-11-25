#include "blend_stack_node.h"

#include <godot_cpp/classes/animation_tree.hpp>
#include <godot_cpp/core/class_db.hpp>

#include <algorithm>
#include <cmath>

using namespace godot;

void BlendStackNode::blend_to(const StringName &p_animation, double p_time, bool p_loop, float p_blend_time, float p_play_rate) {
	Player player;
	player.name = p_animation;
	player.time = p_time;
	player.loops = p_loop;
	player.play_rate = p_play_rate;
	player.id = next_id++;
	// An empty stack has nothing to blend from (InternalBlendTo).
	player.blend_time = players.empty() ? 0.0f : p_blend_time;
	if (!players.empty() && _blend_in_weight(players[0]) < 1.0f && players[0].blend_in_time < max_blend_in_time_to_override) {
		players[0] = player;
	} else {
		players.insert(players.begin(), player);
	}
}

void BlendStackNode::set_play_rate(float p_rate) {
	if (!players.empty()) {
		players[0].play_rate = p_rate;
	}
}

void BlendStackNode::reset() {
	players.clear();
}

StringName BlendStackNode::get_current_animation() const {
	return players.empty() ? StringName() : players[0].name;
}

double BlendStackNode::get_current_time() const {
	return players.empty() ? 0.0 : players[0].time;
}

Array BlendStackNode::get_players() const {
	Array result;
	for (const Player &p : players) {
		Array item;
		item.push_back(p.name);
		item.push_back(p.time);
		item.push_back(p.weight);
		item.push_back(p.id);
		item.push_back(p.delta_position);
		item.push_back(p.delta_rotation);
		item.push_back(p.blend_in_time);
		item.push_back(p.blend_time);
		result.push_back(item);
	}
	return result;
}

float BlendStackNode::_blend_in_weight(const Player &p_player) const {
	if (p_player.blend_time <= 0.0f) {
		return 1.0f;
	}
	const float x = std::min(std::max(p_player.blend_in_time / p_player.blend_time, 0.0f), 1.0f);
	return blend_option == HERMITE_CUBIC ? x * x * (3.0f - 2.0f * x) : x;
}

Ref<Animation> BlendStackNode::_animation(const StringName &p_name) const {
	AnimationTree *tree = Object::cast_to<AnimationTree>(ObjectDB::get_instance(get_processing_animation_tree_instance_id()));
	return tree ? tree->get_animation(p_name) : Ref<Animation>();
}

void BlendStackNode::_describe(Player &r_player) const {
	if (r_player.known) {
		return;
	}
	AnimationTree *tree = Object::cast_to<AnimationTree>(ObjectDB::get_instance(get_processing_animation_tree_instance_id()));
	if (!tree) {
		return;
	}
	Ref<Animation> animation = tree->get_animation(r_player.name);
	ERR_FAIL_COND_MSG(animation.is_null(), vformat("Animation not found: %s", r_player.name));
	r_player.length = animation->get_length();
	const NodePath root_track = tree->get_root_motion_track();
	r_player.position_track = animation->find_track(root_track, Animation::TYPE_POSITION_3D);
	r_player.rotation_track = animation->find_track(root_track, Animation::TYPE_ROTATION_3D);
	r_player.known = true;
}

// Root movement between two times of one pass, relative to the root's heading at the first time.
void BlendStackNode::_root_delta(const Player &p_player, double p_from, double p_to, Vector3 &r_position, Quaternion &r_rotation) const {
	r_position = Vector3();
	r_rotation = Quaternion();
	Ref<Animation> animation = _animation(p_player.name);
	if (animation.is_null()) {
		return;
	}
	Quaternion from_rotation;
	Quaternion to_rotation;
	if (p_player.rotation_track >= 0) {
		from_rotation = animation->rotation_track_interpolate(p_player.rotation_track, p_from);
		to_rotation = animation->rotation_track_interpolate(p_player.rotation_track, p_to);
	}
	if (p_player.position_track >= 0) {
		const Vector3 moved = animation->position_track_interpolate(p_player.position_track, p_to) -
				animation->position_track_interpolate(p_player.position_track, p_from);
		r_position = from_rotation.inverse().xform(moved);
	}
	r_rotation = from_rotation.inverse() * to_rotation;
}

void BlendStackNode::_advance(Player &r_player, double p_delta, Vector3 &r_position, Quaternion &r_rotation, Animation::LoopedFlag &r_looped) {
	_describe(r_player);
	r_position = Vector3();
	r_rotation = Quaternion();
	r_looped = Animation::LOOPED_FLAG_NONE;
	if (r_player.seeked) {
		return;
	}
	const double from = r_player.time;
	r_player.time += p_delta * r_player.play_rate;
	if (r_player.loops && r_player.length > 0.0 && r_player.time >= r_player.length) {
		r_player.time = std::fmod(r_player.time, r_player.length);
		r_looped = Animation::LOOPED_FLAG_END;
		Vector3 end_position;
		Quaternion end_rotation;
		_root_delta(r_player, from, r_player.length, end_position, end_rotation);
		Vector3 start_position;
		Quaternion start_rotation;
		_root_delta(r_player, 0.0, r_player.time, start_position, start_rotation);
		r_position = end_position + end_rotation.xform(start_position);
		r_rotation = end_rotation * start_rotation;
		return;
	}
	if (!r_player.loops && r_player.time > r_player.length) {
		r_player.time = r_player.length; // a finished clip holds its last pose
	}
	_root_delta(r_player, from, r_player.time, r_position, r_rotation);
}

PackedFloat32Array BlendStackNode::_process_animation_node(const PackedFloat64Array &p_playback_info, bool p_test_only) {
	PackedFloat32Array result;
	result.resize(6);
	result.fill(0.0f);
	if (players.empty() || p_playback_info.size() < 2) {
		return result;
	}
	const double delta = p_playback_info[1];
	if (!p_test_only) {
		// Blend clocks (UpdateWithDeltaTime).
		for (int i = 0; i < (int)players.size(); ++i) {
			Player &p = players[i];
			if (p.seeked) {
				continue;
			}
			p.blend_in_time += i == 0 ? (float)delta : (float)delta * std::pow(depth_blend_in_time_multiplier, (float)(i + 1));
		}
		// Weights, newest first; the rest goes down the stack.
		float remaining = 1.0f;
		int used = 0;
		for (int i = 0; i < (int)players.size(); ++i) {
			const bool last = i == (int)players.size() - 1;
			const float in = last ? 1.0f : _blend_in_weight(players[i]);
			players[i].weight = remaining * in;
			remaining *= 1.0f - in;
			used = i + 1;
			if (remaining < 1e-4f) {
				break;
			}
		}
		players.resize(std::max(1, used));

		root_delta_position = Vector3();
		Quaternion rotation_sum(0, 0, 0, 0);
		for (int i = (int)players.size() - 1; i >= 0; --i) {
			Player &p = players[i];
			const bool seeked = p.seeked;
			Vector3 position;
			Quaternion rotation;
			Animation::LoopedFlag looped;
			_advance(p, delta, position, rotation, looped);
			blend_animation(p.name, p.time, seeked ? 0.0 : delta * p.play_rate, seeked, false, p.weight, looped);
			p.seeked = false;
			p.delta_position = position;
			p.delta_rotation = rotation;
			root_delta_position += position * p.weight;
			if (rotation.w < 0.0f) {
				rotation = -rotation;
			}
			rotation_sum = Quaternion(rotation_sum.x + rotation.x * p.weight, rotation_sum.y + rotation.y * p.weight,
					rotation_sum.z + rotation.z * p.weight, rotation_sum.w + rotation.w * p.weight);
		}
		root_delta_rotation = rotation_sum.length_squared() > 0.0f ? rotation_sum.normalized() : Quaternion();
	}
	const Player &top = players[0];
	result.set(0, (float)top.length);
	result.set(1, (float)top.time);
	result.set(2, (float)delta);
	result.set(3, (float)(top.loops ? Animation::LOOP_LINEAR : Animation::LOOP_NONE));
	return result;
}

void BlendStackNode::_bind_methods() {
	ClassDB::bind_method(D_METHOD("blend_to", "animation", "time", "loop", "blend_time", "play_rate"), &BlendStackNode::blend_to);
	ClassDB::bind_method(D_METHOD("set_play_rate", "rate"), &BlendStackNode::set_play_rate);
	ClassDB::bind_method(D_METHOD("reset"), &BlendStackNode::reset);
	ClassDB::bind_method(D_METHOD("get_current_animation"), &BlendStackNode::get_current_animation);
	ClassDB::bind_method(D_METHOD("get_current_time"), &BlendStackNode::get_current_time);
	ClassDB::bind_method(D_METHOD("get_player_count"), &BlendStackNode::get_player_count);
	ClassDB::bind_method(D_METHOD("get_players"), &BlendStackNode::get_players);
	ClassDB::bind_method(D_METHOD("get_root_delta_position"), &BlendStackNode::get_root_delta_position);
	ClassDB::bind_method(D_METHOD("get_root_delta_rotation"), &BlendStackNode::get_root_delta_rotation);
	ClassDB::bind_method(D_METHOD("set_blend_option", "option"), &BlendStackNode::set_blend_option);
	ClassDB::bind_method(D_METHOD("get_blend_option"), &BlendStackNode::get_blend_option);
	ClassDB::bind_method(D_METHOD("set_max_blend_in_time_to_override", "time"), &BlendStackNode::set_max_blend_in_time_to_override);
	ClassDB::bind_method(D_METHOD("get_max_blend_in_time_to_override"), &BlendStackNode::get_max_blend_in_time_to_override);
	ClassDB::bind_method(D_METHOD("set_depth_blend_in_time_multiplier", "multiplier"), &BlendStackNode::set_depth_blend_in_time_multiplier);
	ClassDB::bind_method(D_METHOD("get_depth_blend_in_time_multiplier"), &BlendStackNode::get_depth_blend_in_time_multiplier);
	ADD_PROPERTY(PropertyInfo(Variant::INT, "blend_option", PROPERTY_HINT_ENUM, "Linear,HermiteCubic"), "set_blend_option", "get_blend_option");
	ADD_PROPERTY(PropertyInfo(Variant::FLOAT, "max_blend_in_time_to_override"), "set_max_blend_in_time_to_override", "get_max_blend_in_time_to_override");
	ADD_PROPERTY(PropertyInfo(Variant::FLOAT, "depth_blend_in_time_multiplier"), "set_depth_blend_in_time_multiplier", "get_depth_blend_in_time_multiplier");
}
