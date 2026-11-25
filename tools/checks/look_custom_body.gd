# godot --path . res://tools/checks/look_custom_body.tscn [-- res://path/to/body.glb]
# Close views of the custom body standing (front, back, the arms), running, turning and stopping,
# saved to renders/look_<body>_<view>.png.
extends Node3D

var player: Player
var t := 0.0
# time, input, camera offset from the character (in its facing frame), look height, distance scale
var shots := [
	[1.5, Vector2.ZERO, Vector3(0.6, 0.0, 1.0), 1.15, 1.6, "front"],
	[1.8, Vector2.ZERO, Vector3(-0.4, 0.2, -1.0), 1.1, 1.8, "back"],
	[2.1, Vector2.ZERO, Vector3(1.0, 0.25, 0.35), 1.3, 0.75, "arm"],
	[2.4, Vector2.ZERO, Vector3(0.5, -0.2, 1.0), 0.4, 0.8, "legs"],
	[4.0, Vector2(0, 1), Vector3(-0.8, 0.15, -1.0), 1.0, 2.6, "run_back"],
	[4.4, Vector2(0, 1), Vector3(1.0, 0.1, 0.0), 1.0, 2.6, "run_side"],
	[4.8, Vector2(0, 1), Vector3(-1.0, 0.1, 0.0), 1.0, 2.6, "run_other_side"],
	[5.3, Vector2(0, -1), Vector3(1.0, 0.1, 0.0), 1.0, 2.6, "turn"],
	[6.3, Vector2.ZERO, Vector3(1.0, 0.1, 0.0), 1.0, 2.6, "stop_side"],
	[6.5, Vector2.ZERO, Vector3(-0.3, 0.1, -1.0), 1.0, 2.6, "stop_back"],
]
var cam: Camera3D

func _ready() -> void:
	if not OS.get_cmdline_user_args().is_empty():
		Mannequin.body_mesh = OS.get_cmdline_user_args()[0]
	var main: Node3D = load("res://scenes/main.tscn").instantiate()
	add_child(main)
	await get_tree().process_frame
	player = main.find_children("*", "Player", true, false)[0]
	Input.mouse_mode = Input.MOUSE_MODE_VISIBLE
	player.scripted_input = Vector2.ZERO
	cam = Camera3D.new()
	cam.top_level = true
	cam.fov = 40
	add_child(cam)
	cam.current = true

func _physics_process(dt: float) -> void:
	if player == null:
		return
	t += dt
	if shots.is_empty():
		get_tree().quit()
		return
	var s: Array = shots[0]
	player.scripted_input = s[1]
	var c := player.character.global_position
	var facing := player.visual.global_basis
	var forward := facing.z.slide(Vector3.UP).normalized()
	var right := Vector3.UP.cross(forward)
	var off: Vector3 = s[2]
	cam.global_position = c + Vector3(0, s[3], 0) + (right * off.x + Vector3.UP * off.y + forward * off.z).normalized() * s[4]
	cam.look_at(c + Vector3(0, s[3], 0))
	if t >= s[0]:
		shots.pop_front()
		await RenderingServer.frame_post_draw
		get_viewport().get_texture().get_image().save_png("res://renders/look_%s_%s.png" % [Mannequin.body_mesh.get_file().get_basename(), s[5]])
