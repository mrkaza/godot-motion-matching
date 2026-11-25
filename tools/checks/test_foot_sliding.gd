# godot --headless --fixed-fps 60 --path . --script res://tools/checks/test_foot_sliding.gd [-- strafe]
# How fast planted feet slide over the ground in a set of locomotion scenarios.
# A foot counts as planted while its ball bone is within 3 cm of
# its resting height. Default is orient-to-movement; pass "strafe" for the sample's default strafe mode,
# "body" to measure the custom body (Mannequin.body_mesh) instead of Manny, "body=res://x.glb" for another one.
extends SceneTree

var player: Player
var skeleton: Skeleton3D
var feet := []
var lowest := [INF, INF]
var previous := []
var slides: Array[float] = []
var measuring_ground := true
var camera_spin := 0.0

func _initialize() -> void:
	for a in OS.get_cmdline_user_args():
		if a.begins_with("body="):
			Mannequin.body_mesh = a.trim_prefix("body=")
	var main: Node3D = load("res://scenes/main.tscn").instantiate()
	root.add_child(main)
	await process_frame
	player = main.find_children("*", "Player", true, false)[0]
	Input.mouse_mode = Input.MOUSE_MODE_VISIBLE
	player.character.wants_to_strafe = "strafe" in OS.get_cmdline_user_args()
	skeleton = Mannequin.find_skeleton(player.visual)
	var driver := skeleton
	if Array(OS.get_cmdline_user_args()).any(func(a: String) -> bool: return a.begins_with("body")):
		skeleton = player.visual.find_child("Body", true, false)
		(skeleton.get_parent() as SkeletonModifier3D).modification_processed.connect(_sample)
	else:
		driver.skeleton_updated.connect(_sample)
	feet = ["ball_l", "ball_r"].map(func(b): return skeleton.find_bone(b))
	player.scripted_input = Vector2.ZERO
	await create_timer(1.0).timeout
	measuring_ground = false
	print("mode: ", "strafe" if player.character.wants_to_strafe else "orient to movement")
	await _scenario("straight_run", [[Vector2(0, 1), 2.0, 0.0]])
	await _scenario("turn_45", [[Vector2(0, 1), 1.5, 0.0], [Vector2(0.707, 0.707), 1.0, 0.0]])
	await _scenario("turn_90", [[Vector2(0, 1), 1.5, 0.0], [Vector2(1, 0), 1.0, 0.0]])
	await _scenario("turn_135", [[Vector2(0, 1), 1.5, 0.0], [Vector2(0.707, -0.707), 1.2, 0.0]])
	await _scenario("turn_180", [[Vector2(0, 1), 1.5, 0.0], [Vector2(0, -1), 1.2, 0.0]])
	await _scenario("w_then_wd", [[Vector2(0, 1), 1.0, 0.0], [Vector2(0.707, 0.707), 1.0, 0.0], [Vector2(0, 1), 1.0, 0.0]])
	await _scenario("camera_spin", [[Vector2(0, 1), 2.0, 90.0]])
	await _scenario("start_stop", [[Vector2(0, 1), 1.0, 0.0], [Vector2.ZERO, 1.0, 0.0]])
	quit()

func _scenario(label: String, steps: Array) -> void:
	player.scripted_input = Vector2.ZERO
	await create_timer(0.8).timeout
	slides.clear()
	for step in steps:
		player.scripted_input = step[0]
		camera_spin = step[2]
		await create_timer(step[1]).timeout
	camera_spin = 0.0
	player.scripted_input = Vector2.ZERO
	slides.sort()
	var n := slides.size()
	var mean: float = slides.reduce(func(a, b): return a + b, 0.0) / maxi(n, 1)
	print("SLIDE %-13s planted_samples=%d mean=%.2f m/s p50=%.2f m/s p90=%.2f m/s max=%.2f m/s" % [label, n, mean,
		slides[n / 2] if n > 0 else 0.0, slides[n * 9 / 10] if n > 0 else 0.0, slides.back() if n > 0 else 0.0])
	await create_timer(1.0).timeout

var _last_frame := -1

func _sample() -> void:
	# The skeleton can update more than once a frame; one sample per physics frame.
	var frame := Engine.get_physics_frames()
	if frame == _last_frame:
		return
	_last_frame = frame
	player.camera_yaw += deg_to_rad(camera_spin) / 60.0
	var now := feet.map(func(b): return (skeleton.global_transform * skeleton.get_bone_global_pose(b)).origin)
	if measuring_ground:
		for i in now.size():
			lowest[i] = minf(lowest[i], now[i].y)
	elif previous.size() == now.size():
		for i in now.size():
			if now[i].y < lowest[i] + 0.03:
				var d: Vector3 = now[i] - previous[i]
				var speed := Vector2(d.x, d.z).length() * 60.0
				slides.append(speed)
				if speed > 5.0 and "spikes" in OS.get_cmdline_user_args():
					var m := player.matcher
					var pl: Array = m.blend.get_players()
					print("  spike %.1f m/s foot=%d h=%.3f lowest=%.3f vis=%.1f players=%s" % [speed, i, now[i].y, lowest[i], rad_to_deg(m.visual_yaw), pl.map(func(x): return "%s@%.2f w%.2f" % [str(x[0]).get_file(), x[1], x[2]])])
	previous = now
