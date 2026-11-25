# godot --path . res://tools/checks/check_custom_body.tscn [-- res://path/to/body.glb]
# Walks the player with the custom body (Mannequin.body_mesh). Prints how far the body's joints are
# from Manny's (hidden) final pose, read when the CustomBody modifier has run, and the lowest point of
# each foot (the sole should stay near the ground). Saves side views to renders/custom_body_<body>_*.png.
extends Node3D

var player: Player
var t := 0.0
var shots := [0.5, 2.0, 2.4, 4.5, 6.5, 8.0]
var phases := [[0.0, Vector2.ZERO], [1.0, Vector2(0, 1)], [3.5, Vector2(1, 0)], [6.0, Vector2(0, -1)], [7.5, Vector2.ZERO], [9.0, null]]
var cam: Camera3D
var worst := {}
var ms: Skeleton3D
var bs: Skeleton3D

func _ready() -> void:
	if not OS.get_cmdline_user_args().is_empty():
		Mannequin.body_mesh = OS.get_cmdline_user_args()[0]
	var main: Node3D = load("res://scenes/main.tscn").instantiate()
	add_child(main)
	await get_tree().process_frame
	player = main.find_children("*", "Player", true, false)[0]
	Input.mouse_mode = Input.MOUSE_MODE_VISIBLE
	player.scripted_input = Vector2.ZERO
	ms = Mannequin.find_skeleton(player.visual)
	bs = player.visual.find_child("Body", true, false)
	(bs.get_parent() as SkeletonModifier3D).modification_processed.connect(_measure)
	cam = Camera3D.new()
	cam.top_level = true
	add_child(cam)
	cam.current = true

func _measure() -> void:
	if t < 0.3:
		return
	for bn in ["pelvis", "head", "hand_l", "hand_r", "foot_l", "foot_r"]:
		var a := ms.global_transform * ms.get_bone_global_pose(ms.find_bone(bn)).origin
		var b := bs.global_transform * bs.get_bone_global_pose(bs.find_bone(bn)).origin
		worst[bn] = maxf(worst.get(bn, 0.0), a.distance_to(b))

func _physics_process(dt: float) -> void:
	if player == null:
		return
	t += dt
	var input = phases[0][1]
	for p in phases:
		if t >= p[0]:
			input = p[1]
	if input == null:
		for k in worst:
			print("%s: worst gap body vs Manny %.3f m" % [k, worst[k]])
		get_tree().quit()
		return
	player.scripted_input = input
	var c := player.character.global_position
	cam.global_position = c + Vector3(3.2, 1.2, 0.0)
	cam.look_at(c + Vector3(0, 0.9, 0))
	if not shots.is_empty() and t >= shots[0]:
		shots.pop_front()
		await RenderingServer.frame_post_draw
		get_viewport().get_texture().get_image().save_png("res://renders/custom_body_%s_%.1f.png" % [Mannequin.body_mesh.get_file().get_basename(), t])
