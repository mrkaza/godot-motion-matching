// Animation tree node that works like Unreal's Blend Stack (AnimNode_BlendStack.cpp):
// - blend_to() puts a clip on top. The newest player's weight is alpha(blend-in time / blend time);
//   each older player gets that share of what is left, and the oldest gets the rest.
// - A request replaces the newest player instead when that one has blended in for less than
//   max_blend_in_time_to_override (and isn't fully in yet). An empty stack starts with no blend.
// - Older players' blend clocks run faster by depth_blend_in_time_multiplier^(depth + 1).
// - Players whose weight drops to zero are removed.
// Root motion of each clip is taken relative to its own heading and blended by weight.
// get_players() also returns each player's id (new for every blend_to) and its own root delta this
// frame, so callers can run per-player nodes like the blend stack's per-sample graph.
#pragma once

#include <godot_cpp/classes/animation.hpp>
#include <godot_cpp/classes/animation_node_extension.hpp>

#include <vector>

namespace godot {

class BlendStackNode : public AnimationNodeExtension {
	GDCLASS(BlendStackNode, AnimationNodeExtension)

public:
	enum BlendOption {
		LINEAR = 0,
		HERMITE_CUBIC = 1,
	};

	void blend_to(const StringName &p_animation, double p_time, bool p_loop, float p_blend_time, float p_play_rate);
	void set_play_rate(float p_rate);
	void reset();

	StringName get_current_animation() const;
	double get_current_time() const;
	int get_player_count() const { return (int)players.size(); }
	Vector3 get_root_delta_position() const { return root_delta_position; }
	Quaternion get_root_delta_rotation() const { return root_delta_rotation; }
	// [name, time, weight, id, root delta position, root delta rotation, blend-in time, blend time]
	// per player, newest first.
	Array get_players() const;

	void set_blend_option(int p_option) { blend_option = p_option; }
	int get_blend_option() const { return blend_option; }
	void set_max_blend_in_time_to_override(float p_time) { max_blend_in_time_to_override = p_time; }
	float get_max_blend_in_time_to_override() const { return max_blend_in_time_to_override; }
	void set_depth_blend_in_time_multiplier(float p_multiplier) { depth_blend_in_time_multiplier = p_multiplier; }
	float get_depth_blend_in_time_multiplier() const { return depth_blend_in_time_multiplier; }

	virtual PackedFloat32Array _process_animation_node(const PackedFloat64Array &p_playback_info, bool p_test_only) override;

protected:
	static void _bind_methods();

private:
	struct Player {
		StringName name;
		double time = 0.0;
		double length = 0.0;
		bool loops = false;
		bool known = false;
		int position_track = -1;
		int rotation_track = -1;
		bool seeked = true;
		float blend_time = 0.0f;
		float blend_in_time = 0.0f;
		float play_rate = 1.0f;
		float weight = 0.0f;
		int64_t id = 0;
		Vector3 delta_position;
		Quaternion delta_rotation;
	};

	float _blend_in_weight(const Player &p_player) const;
	void _describe(Player &r_player) const;
	void _advance(Player &r_player, double p_delta, Vector3 &r_position, Quaternion &r_rotation, Animation::LoopedFlag &r_looped);
	void _root_delta(const Player &p_player, double p_from, double p_to, Vector3 &r_position, Quaternion &r_rotation) const;
	Ref<Animation> _animation(const StringName &p_name) const;

	std::vector<Player> players; // [0] is the newest
	int64_t next_id = 1;
	int blend_option = HERMITE_CUBIC;
	float max_blend_in_time_to_override = 0.0f;
	float depth_blend_in_time_multiplier = 1.0f;
	Vector3 root_delta_position;
	Quaternion root_delta_rotation;
};

} // namespace godot
