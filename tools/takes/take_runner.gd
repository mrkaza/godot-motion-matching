# Records scripted gameplay takes in the showcase level with Godot's movie writer:
#   godot --path . --write-movie renders/takes/<take>.avi --fixed-fps 60 res://tools/takes/take_runner.tscn -- take=<name>
# Each take is a timeline of steps: [time, {input: Vector2 (camera space), sprint, walk, crouch,
# strafe, jump, traverse, ragdoll, interact, debug}] with a camera:
#   follow: behind the character at the camera yaw (back, up, right, pitch)
#   dolly:  a fixed world offset from the character, smoothed, always looking at it
#   fixed:  a fixed position looking at the character
#   player: the player's own camera (scripts/game/player.gd); a step's "zoom": n turns the mouse
#           wheel n notches (negative zooms in)
# "traverse" retries the traversal check every frame until it starts (no fallback jump), so the
# press lands at the right distance; a take's "traverse_all": true keeps doing that whenever no
# action plays (runs a whole course). "interact": [type, distance] retries the interaction (Shove or
# Takedown) every frame until the NPC is that close and it starts. "npc": {pos, yaw} puts the showcase's
# NPC there, standing (no patrol). Events (clip changes, traversal, ragdoll, interactions) print to stdout.
extends Node3D

const TAKES := {
	# Starts, stops, pivots and strafes with the debug view on, from behind.
	"locomotion": {
		"start": Vector3(0, 0, -6), "yaw": PI, "camera_yaw": 0.0, "length": 15.0, "debug": true,
		"camera": {"mode": "follow", "back": 3.2, "up": 0.25, "right": 0.45, "pitch": -0.12, "fov": 55.0, "look_height": 1.0},
		"steps": [
			[0.0, {"input": Vector2.ZERO, "strafe": true}],
			[1.0, {"input": Vector2(0, 1)}],
			[3.0, {"input": Vector2(0, -1)}],
			[4.6, {"input": Vector2(1, 0)}],
			[6.0, {"input": Vector2(-1, 0)}],
			[7.4, {"input": Vector2.ZERO}],
			[8.6, {"input": Vector2(0, 1), "strafe": false}],
			[10.0, {"input": Vector2(1, 0)}],
			[11.2, {"input": Vector2(0, -1)}],
			[12.6, {"input": Vector2.ZERO}],
		],
	},
	# Run up onto the 1.2 m block (mantle), across it and off the far side.
	"mantle": {
		"start": Vector3(0, 0, 3), "yaw": 0.0, "camera_yaw": PI, "length": 6.5, "debug": false,
		"camera": {"mode": "dolly", "offset": Vector3(4.5, 1.8, 0.5), "look_height": 1.2, "fov": 50.0},
		"steps": [
			[0.0, {"input": Vector2.ZERO, "strafe": false}],
			[0.5, {"input": Vector2(0, 1)}],
			[1.0, {"traverse": true}],
			[5.0, {"input": Vector2.ZERO}],
		],
	},
	# Walk up to the NPC, stop, shove it (F): it falls and gets up.
	"shove": {
		"start": Vector3(2, 0, -5), "yaw": 0.0, "camera_yaw": PI, "length": 10.0, "debug": false,
		"npc": {"pos": Vector3(2, 0, -2.2), "yaw": PI},
		"camera": {"mode": "fixed", "position": Vector3(7.0, 1.7, -0.6), "look_height": 0.6, "fov": 50.0},
		"steps": [
			[0.0, {"input": Vector2.ZERO, "strafe": false, "walk": true}],
			[0.3, {"input": Vector2(0, 1)}],
			[1.2, {"input": Vector2.ZERO}],
			[1.9, {"interact": ["Shove", 1.3]}],
		],
	},
	# Run at the NPC (standing side-on) and tackle it (F at run speed): both go down and get up.
	"tackle": {
		"start": Vector3(-2, 0, -14), "yaw": 0.0, "camera_yaw": PI, "length": 11.0, "debug": false,
		"npc": {"pos": Vector3(-2, 0, -3), "yaw": PI * 0.5},
		"camera": {"mode": "fixed", "position": Vector3(2.8, 1.6, -0.8), "look_height": 0.6, "fov": 55.0},
		"steps": [
			[0.0, {"input": Vector2.ZERO, "strafe": false}],
			[0.3, {"input": Vector2(0, 1)}],
			[0.4, {"interact": ["Shove", 1.95]}],
		],
	},
	# The player's camera: zoom out and in with the wheel, then run at the NPC and tackle it.
	"tackle_player_camera": {
		"start": Vector3(-2, 0, -14), "yaw": 0.0, "camera_yaw": PI, "length": 9.0, "debug": false,
		"npc": {"pos": Vector3(-2, 0, -3), "yaw": PI * 0.5},
		"camera": {"mode": "player"},
		"steps": [
			[0.0, {"input": Vector2.ZERO, "strafe": false}],
			[0.5, {"zoom": 4}],
			[1.3, {"zoom": -7}],
			[2.1, {"zoom": 3}],
			[2.6, {"input": Vector2(0, 1)}],
			[2.7, {"interact": ["Shove", 1.95]}],
		],
	},
	# Knocked down standing, then Space to get up (the player's get-up).
	"ragdoll_getup": {
		"start": Vector3(0, 0, -16), "yaw": 0.0, "camera_yaw": PI, "length": 7.0, "debug": false,
		"camera": {"mode": "fixed", "position": Vector3(3.5, 1.6, -13.0), "look_height": 0.5, "fov": 50.0},
		"steps": [
			[0.0, {"input": Vector2.ZERO, "strafe": false}],
			[0.5, {"ragdoll": Vector3(0, 0, -60)}],
			[3.0, {"jump": true}],
		],
	},
	# Broken builds for the time-lapse (the bugs fixed during the build, brought back on purpose):
	# the bind pose with no animation, and blends popping with the glTF's bone rests.
	"broken_tpose": {
		"start": Vector3(0, 0, -2), "yaw": PI, "camera_yaw": 0.0, "length": 2.0, "debug": false, "broken": true, "no_anim": true,
		"camera": {"mode": "fixed", "position": Vector3(1.0, 1.4, -6.5), "look_height": 1.0, "fov": 40.0},
		"steps": [[0.0, {"input": Vector2.ZERO}]],
	},
	"broken_pops": {
		"start": Vector3(0, 0, -6), "yaw": PI, "camera_yaw": 0.0, "length": 5.0, "debug": false, "broken": true,
		"camera": {"mode": "follow", "back": 3.2, "up": 0.25, "right": 0.45, "pitch": -0.12, "fov": 55.0, "look_height": 1.0},
		"steps": [
			[0.0, {"input": Vector2.ZERO, "strafe": false}],
			[0.5, {"input": Vector2(0, 1)}],
			[2.0, {"input": Vector2(1, 0)}],
			[3.2, {"input": Vector2(0, -1)}],
		],
	},
	"mantle_side": {
		"start": Vector3(0, 0, 3), "yaw": 0.0, "camera_yaw": PI, "length": 4.5, "debug": false,
		"camera": {"mode": "fixed", "position": Vector3(3.2, 1.6, 6.5), "look_height": 1.1, "fov": 50.0},
		"steps": [
			[0.0, {"input": Vector2.ZERO, "strafe": false}],
			[0.5, {"input": Vector2(0, 1)}],
			[1.0, {"traverse": true}],
			[3.0, {"input": Vector2.ZERO}],
		],
	},
	# Turns while running, facing the movement (not strafing): 90 right, 180, 90 left, 45, stop; high camera.
	"turns": {
		"start": Vector3(0, 0, -12), "yaw": 0.0, "camera_yaw": PI, "length": 9.0, "debug": false,
		"camera": {"mode": "fixed", "position": Vector3(-7.0, 7.0, -6.0), "look_height": 0.6, "fov": 55.0},
		"steps": [
			[0.0, {"input": Vector2.ZERO, "strafe": false}],
			[0.3, {"input": Vector2(0, 1)}],
			[1.8, {"input": Vector2(1, 0)}],
			[3.2, {"input": Vector2(-1, 0)}],
			[4.8, {"input": Vector2(0, 1)}],
			[6.2, {"input": Vector2(0.7, 0.7)}],
			[7.4, {"input": Vector2.ZERO}],
		],
	},
	# Slides (the Mover character's): sprint and crouch, stand up running; run and crouch, let go of
	# the stick while sliding, crouch walk out.
	"slide": {
		"start": Vector3(0, 0, -24), "yaw": 0.0, "camera_yaw": PI, "length": 7.5, "debug": false,
		"camera": {"mode": "dolly", "offset": Vector3(4.5, 1.4, 1.0), "look_height": 0.7, "fov": 50.0},
		"steps": [
			[0.0, {"input": Vector2.ZERO, "strafe": false}],
			[0.3, {"input": Vector2(0, 1), "sprint": true}],
			[1.8, {"crouch": true}],
			[3.4, {"crouch": false, "sprint": false}],
			[4.4, {"crouch": true}],
			[4.8, {"input": Vector2.ZERO}],
			[6.6, {"crouch": false}],
		],
	},
	# Side view of a run and a stop, whole body in frame (hands and feet review).
	"run_stop_side": {
		"start": Vector3(0, 0, -10), "yaw": 0.0, "camera_yaw": PI, "length": 4.0, "debug": false,
		"camera": {"mode": "fixed", "position": Vector3(3.2, 0.9, -5.5), "look_height": 0.8, "fov": 50.0},
		"steps": [
			[0.0, {"input": Vector2.ZERO, "strafe": false}],
			[0.3, {"input": Vector2(0, 1)}],
			[1.6, {"input": Vector2.ZERO}],
		],
	},
	# Ending: run toward the camera, stop, stand there.
	"ending": {
		"start": Vector3(0, 0, -2), "yaw": PI, "camera_yaw": 0.0, "length": 5.0, "debug": false,
		"camera": {"mode": "fixed", "position": Vector3(0.6, 1.5, -9.5), "look_height": 1.1, "fov": 40.0},
		"steps": [
			[0.0, {"input": Vector2.ZERO, "strafe": false}],
			[0.3, {"input": Vector2(0, 1)}],
			[1.5, {"input": Vector2.ZERO}],
		],
	},
}

var take: Dictionary
var player: Player
var t := 0.0
var step := 0
var camera: Camera3D
var traversing := false
var interact := []
var _last_npc := ""
var _last_clip := ""


func _ready() -> void:
	var name := "locomotion"
	for a in OS.get_cmdline_user_args():
		if a.begins_with("take="):
			name = a.trim_prefix("take=")
	take = TAKES[name]
	Mannequin.use_clip_rest = not take.get("broken", false)
	var main: Node3D = load("res://scenes/main.tscn").instantiate()
	add_child(main)
	await get_tree().process_frame
	player = main.player
	Input.mouse_mode = Input.MOUSE_MODE_VISIBLE
	player.character.global_position = take["start"]
	player.character.yaw = take["yaw"]
	player.character.control_yaw = take["yaw"]
	player.matcher.visual_yaw = take["yaw"]
	player.camera_yaw = take["camera_yaw"]
	player.scripted_input = Vector2.ZERO
	player.reset_physics_interpolation()  # placed, not moved: no in-between frame from the spawn point
	for c in player.components:
		if "shown" in c:
			c.shown = take.get("debug", false)
	if take.get("no_anim", false):
		player.matcher_enabled = false
		player.matcher.tree.active = false
		Mannequin.find_skeleton(player.visual).reset_bone_poses()
	if take.has("npc") and main.get("npc") != null:
		var npc: Player = main.npc
		var n: Dictionary = take["npc"]
		npc.character.global_position = n["pos"]
		npc.character.yaw = n["yaw"]
		npc.matcher.visual_yaw = n["yaw"]
		npc.reset_physics_interpolation()
		for c in npc.components:
			if "patrol" in c:
				c.patrol = false
	if take["camera"]["mode"] == "player":
		return
	camera = Camera3D.new()
	camera.fov = take["camera"].get("fov", 55.0)
	add_child(camera)
	camera.current = true
	print("TAKE ", name)


var _last_pos := Vector3.INF


func _physics_process(dt: float) -> void:
	if player == null:
		return
	t += dt
	var steps: Array = take["steps"]
	while step < steps.size() and t >= steps[step][0]:
		_apply(steps[step][1])
		step += 1
	if traversing or (take.get("traverse_all", false) and player.matcher.action_clip == ""):
		for c in player.components:
			if c.has_method("try_traversal_action") and c.on_jump_pressed():
				traversing = false
				print("EVENT %.2f traversal %s" % [t, c.result.get("action_type", c.result)])
				break
	if not interact.is_empty():
		for c in player.components:
			if c.has_method("try_interaction"):
				var npc: Player = get_child(0).get("npc")
				if npc == null or npc.character.global_position.distance_to(player.character.global_position) <= interact[1]:
					var r: Dictionary = c.try_interaction(interact[0])
					if not r.is_empty():
						interact = []
						player.scripted_input = Vector2.ZERO
						print("EVENT %.2f interaction %s at %.2f" % [t, String(r["asset"]).get_file(), r["time"]])
	_log_events()
	if t >= take["length"]:
		print("END %.2f at %s" % [t, player.character.global_position])
		get_tree().quit()
	_update_camera(dt)


func _apply(s: Dictionary) -> void:
	var c := player.character
	if s.has("input"): player.scripted_input = s["input"]
	if s.has("sprint"): c.wants_to_sprint = s["sprint"]
	if s.has("walk"): c.wants_to_walk = s["walk"]
	if s.has("crouch"): c.wants_to_crouch = s["crouch"]
	if s.has("strafe"): c.wants_to_strafe = s["strafe"]
	if s.get("jump", false): player.press_jump()
	if s.get("traverse", false): traversing = true
	if s.has("interact"): interact = s["interact"]
	if s.has("zoom"):
		for i in absi(int(s["zoom"])):
			var wheel := InputEventMouseButton.new()
			wheel.button_index = MOUSE_BUTTON_WHEEL_DOWN if int(s["zoom"]) > 0 else MOUSE_BUTTON_WHEEL_UP
			wheel.pressed = true
			player._unhandled_input(wheel)
	if s.has("ragdoll"):
		for comp in player.components:
			if comp.has_method("start_ragdoll"):
				comp.start_ragdoll(s["ragdoll"], player.character.global_position + Vector3.UP * 1.3)


func _log_events() -> void:
	var m := player.matcher
	var clip := ""
	if m.action_clip != "":
		clip = "action " + m.action_clip.get_file().get_basename()
	elif m.current_pose >= 0 and m.databases.has(m.current_db):
		var db: PoseDatabase = m.databases[m.current_db]
		clip = db.entry_clip[db.pose_entry[m.current_pose]].get_file().get_basename()
	for c in player.components:
		if c.has_method("is_ragdoll") and c.is_ragdoll():
			clip = "RAGDOLL"
	if clip != _last_clip:
		print("EVENT %.2f %s" % [t, clip])
		_last_clip = clip
	var at := player.character.global_position
	if _last_pos != Vector3.INF and at.distance_to(_last_pos) > 2.0:
		print("EVENT %.2f teleport to %s" % [t, at])
	_last_pos = at
	var npc: Player = get_child(0).get("npc")
	if npc != null:
		var state := "npc " + (npc.matcher.action_clip.get_file().get_basename() if npc.matcher.action_clip != "" else "matching")
		for c in npc.components:
			if c.has_method("is_ragdoll") and c.is_ragdoll():
				state = "npc RAGDOLL"
		if state != _last_npc:
			print("EVENT %.2f %s" % [t, state])
			_last_npc = state


func _update_camera(dt: float) -> void:
	var cam: Dictionary = take["camera"]
	if cam["mode"] == "player":
		return
	# Follow the body (pelvis), not the capsule node: the ragdoll leaves the capsule behind.
	var sk := Mannequin.find_skeleton(player.visual)
	var pelvis := (sk.global_transform * sk.get_bone_global_pose(sk.find_bone("pelvis"))).origin
	var focus := Vector3(pelvis.x, player.character.global_position.y if pelvis.y > 0.6 else pelvis.y - 0.15, pelvis.z)
	var target := focus + Vector3.UP * float(cam.get("look_height", 1.1))
	match cam["mode"]:
		"fixed":
			camera.global_position = cam["position"]
		"dolly":
			var want: Vector3 = focus + cam["offset"]
			camera.global_position = want if t <= dt * 1.5 else camera.global_position.lerp(want, 1.0 - exp(-dt * 8.0))
		_:
			var rot := Basis(Vector3.UP, player.camera_yaw) * Basis(Vector3.RIGHT, float(cam["pitch"]))
			var want := player.character.global_position + Vector3.UP * 1.4 + rot * Vector3(cam["right"], cam["up"], cam["back"])
			camera.global_position = want if t <= dt * 1.5 else camera.global_position.lerp(want, 1.0 - exp(-dt * 5.0))
	camera.look_at(target, Vector3.UP)
