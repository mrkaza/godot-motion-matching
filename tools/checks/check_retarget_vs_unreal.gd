# godot --headless --path . --script res://tools/checks/check_retarget_vs_unreal.gd -- <ue_fbx_dir> [NO_CURVES]
# Compares scripts/motion/retarget.gd with Unreal's own retarget of the same clips: <ue_fbx_dir> holds
# manny_<clip>.fbx files made by Unreal's IKRetargetBatchOperation with RTG_UEFN_to_UE5_Mannequin (the
# offline retarget runs the asset settings, so the hand curves are left at 0 here too). Plays each UEFN
# clip on Manny with the retarget and the Unreal result side by side and prints how far each bone is
# from Unreal's, relative to the root bone (cm).
extends SceneTree

const RETARGET := preload("res://scripts/motion/retarget.gd")
const CLIPS := {
	"M_Neutral_Stand_Idle_Loop": "Idle/M_Neutral_Stand_Idle_Loop",
	"M_Neutral_Traversal_Hurdle_1_0_run_F_V2_Lfoot": "Traversal/Hurdle/M_Neutral_Traversal_Hurdle_1_0_run_F_V2_Lfoot",
	"M_Neutral_Traversal_Mantle_1_0_stand_F_Rfoot": "Traversal/Mantle/M_Neutral_Traversal_Mantle_1_0_stand_F_Rfoot",
	"M_Neutral_Traversal_Climb_Start_2_5_stand_F_Lfoot": "Traversal/Climb/M_Neutral_Traversal_Climb_Start_2_5_stand_F_Lfoot",
	"M_Neutral_Traversal_Vault_1_0_walk_F_Rfoot": "Traversal/Vault/M_Neutral_Traversal_Vault_1_0_walk_F_Rfoot",
}
const REPORT := ["pelvis", "spine_05", "head", "thigh_l", "calf_l", "foot_l", "ball_l", "foot_r", "upperarm_l", "lowerarm_l", "hand_l", "hand_r", "middle_03_l", "index_03_r"]

var _drawn := {}


func _initialize() -> void:
	var dir: String = OS.get_cmdline_user_args()[0]
	for clip: String in CLIPS:
		await _compare(dir.path_join("manny_%s.fbx" % clip), "res://extracted/anims/%s.fbx" % CLIPS[clip], clip)
	quit()


func _compare(ue_path: String, clip_path: String, label: String) -> void:
	# Unreal's result.
	var doc := FBXDocument.new()
	var state := FBXState.new()
	if doc.append_from_file(ue_path, state) != OK:
		print("cannot read ", ue_path)
		return
	var ue_scene: Node = doc.generate_scene(state)
	root.add_child(ue_scene)
	var ue_sk: Skeleton3D = ue_scene.find_children("*", "Skeleton3D", true, false)[0]
	var ue_ap: AnimationPlayer = ue_scene.find_children("*", "AnimationPlayer", true, false)[0]
	var ue_anim: StringName = ue_ap.get_animation_list()[0]
	ue_ap.callback_mode_process = AnimationMixer.ANIMATION_CALLBACK_MODE_PROCESS_MANUAL
	ue_ap.play(ue_anim)
	# Ours.
	var body := Mannequin.instantiate()
	root.add_child(body)
	var sk := Mannequin.find_skeleton(body)
	var lib: AnimationLibrary = load(clip_path).duplicate(true)
	var anim := lib.get_animation(lib.get_animation_list()[0])
	Mannequin.strip_limb_positions(anim)
	var ap := AnimationPlayer.new()
	body.add_child(ap)
	ap.root_node = ap.get_path_to(sk.get_parent())
	ap.add_animation_library("c", lib)
	ap.callback_mode_process = AnimationMixer.ANIMATION_CALLBACK_MODE_PROCESS_MANUAL
	ap.play("c/" + lib.get_animation_list()[0])
	var rt = RETARGET.new()
	rt.setup(sk)
	sk.skeleton_updated.connect(_grab.bind(sk))
	var err := {}
	var worst := {}
	var n := 0
	var t := 0.0
	while t < anim.length:
		ue_ap.seek(t, true)
		ap.seek(t, true)
		await process_frame
		await process_frame
		var ue_root := ue_sk.get_bone_global_pose(ue_sk.find_bone("root"))
		var our_root: Transform3D = _drawn.get(sk.find_bone("root"), Transform3D.IDENTITY)
		for b in sk.get_bone_count():
			var bn := sk.get_bone_name(b)
			var ub := ue_sk.find_bone(bn)
			if ub < 0 or not _drawn.has(b):
				continue
			var ue_p := (ue_root.affine_inverse() * ue_sk.get_bone_global_pose(ub)).origin
			var our_p := (our_root.affine_inverse() * (_drawn[b] as Transform3D)).origin
			var e := ue_p.distance_to(our_p) * 100.0
			err[bn] = err.get(bn, 0.0) + e
			if e > worst.get(bn, [0.0])[0]:
				worst[bn] = [e, t]
		n += 1
		t += 0.1
	var line := "%s (%d samples): mean/max cm" % [label, n]
	for bn: String in REPORT:
		if err.has(bn):
			line += "  %s %.1f/%.1f@%.1f" % [bn, err[bn] / n, worst[bn][0], worst[bn][1]]
	var total := 0.0
	for bn: String in err:
		total += err[bn] / n
	print(line, "  | all-bone mean %.2f" % (total / err.size()))
	sk.skeleton_updated.disconnect(_grab)
	_drawn.clear()
	body.queue_free()
	ue_scene.queue_free()
	await process_frame


func _grab(sk: Skeleton3D) -> void:
	for b in sk.get_bone_count():
		_drawn[b] = sk.get_bone_global_pose(b)
