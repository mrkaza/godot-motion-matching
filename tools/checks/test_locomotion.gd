# godot --headless --fixed-fps 60 --path . --script res://tools/checks/test_locomotion.gd
# Drives the player through idle, start, run, 180 turn, stop and prints what motion matching picks.
extends SceneTree

var player: Player
var t := 0.0
var next_print := 0.0
var phases := [
	[0.0, "idle", Vector2.ZERO],
	[1.0, "start+run", Vector2(0, 1)],
	[3.5, "turn 180", Vector2(0, -1)],
	[5.5, "turn 90", Vector2(1, 0)],
	[7.0, "stop", Vector2.ZERO],
	[8.5, "end", Vector2.ZERO],
]

func _initialize() -> void:
	var main: Node3D = load("res://scenes/main.tscn").instantiate()
	root.add_child(main)
	await process_frame
	player = main.find_children("*", "Player", true, false)[0]
	Input.mouse_mode = Input.MOUSE_MODE_VISIBLE
	player.scripted_input = Vector2.ZERO
	physics_frame.connect(_step)

func _step() -> void:
	var dt := 1.0 / 60.0
	t += dt
	var phase = phases[0]
	for p in phases:
		if t >= p[0]:
			phase = p
	if phase[1] == "end":
		quit()
		return
	player.scripted_input = phase[2]
	if t >= next_print:
		next_print += 0.25
		var m := player.matcher
		var db: String = m.current_db.get_file()
		var clip := ""
		if m.current_pose >= 0:
			var d: PoseDatabase = m.databases[m.current_db]
			clip = d.entry_clip[d.pose_entry[m.current_pose]].get_file().get_basename()
		print("t=%.2f %-9s speed=%5.0f yaw=%6.1f visual=%6.1f players=%d cost=%.3f db=%s clip=%s" % [t, phase[1], player.character.speed_2d(), rad_to_deg(player.character.yaw), rad_to_deg(m.visual_yaw), m.blend.get_player_count(), m.current_cost, db, clip])
