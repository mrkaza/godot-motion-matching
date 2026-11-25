# godot --headless --fixed-fps 60 --path . --script res://tools/checks/test_modes.gd
# Walk, sprint, crouch, jump and orient-to-movement: prints the database and clip each mode picks.
extends SceneTree

var player: Player
var t := 0.0
var next_print := 0.0
var step := 0
# [start time, label, input, setup callable]
var phases: Array

func _initialize() -> void:
	var main: Node3D = load("res://scenes/main.tscn").instantiate()
	root.add_child(main)
	await process_frame
	player = main.find_children("*", "Player", true, false)[0]
	Input.mouse_mode = Input.MOUSE_MODE_VISIBLE
	var c := player.character
	phases = [
		[0.0, "walk", Vector2(0, 1), func(): c.wants_to_walk = true],
		[2.0, "walk stop", Vector2.ZERO, func(): pass],
		[3.0, "sprint", Vector2(0, 1), func(): c.wants_to_walk = false; c.wants_to_sprint = true],
		[5.5, "sprint stop", Vector2.ZERO, func(): c.wants_to_sprint = false],
		[6.5, "crouch idle", Vector2.ZERO, func(): c.wants_to_crouch = true],
		[7.5, "crouch move", Vector2(0, 1), func(): pass],
		[9.0, "stand run", Vector2(0, 1), func(): c.wants_to_crouch = false],
		[10.0, "jump", Vector2(0, 1), func(): c.jump()],
		[11.5, "orient run", Vector2(1, 0), func(): c.wants_to_strafe = false],
		[13.0, "orient turn", Vector2(0, -1), func(): pass],
		[14.5, "end", Vector2.ZERO, func(): pass],
	]
	player.scripted_input = Vector2.ZERO
	physics_frame.connect(_step)

func _step() -> void:
	t += 1.0 / 60.0
	while step < phases.size() and t >= phases[step][0]:
		phases[step][3].call()
		player.scripted_input = phases[step][2]
		step += 1
	if step >= phases.size():
		quit()
		return
	if t >= next_print:
		next_print += 0.25
		var m := player.matcher
		var clip := ""
		if m.current_pose >= 0:
			var d: PoseDatabase = m.databases[m.current_db]
			clip = d.entry_clip[d.pose_entry[m.current_pose]].get_file().get_basename()
		print("t=%5.2f %-12s %-8s spd=%4.0f gait=%-6s mode=%-8s db=%-34s clip=%s" % [t, phases[step - 1][1], m.vars.get("MovementState"), player.character.speed_2d(), m.vars.get("Gait"), m.vars.get("MovementMode"), m.current_db.get_file(), clip])
