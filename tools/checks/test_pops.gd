# godot --headless --fixed-fps 60 --path . --script res://tools/checks/test_pops.gd
# Looks for pose pops: any bone moving more than 8 cm in one frame in the character's own frame
# (skeleton space, so walking and turning don't count).
extends SceneTree
var player: Player
var sk: Skeleton3D
var prev := []
var f := 0
var t := 0.0
var inputs := [[0.0, Vector2.ZERO], [1.0, Vector2(0, 1)], [3.0, Vector2(0.7, 0.7)], [4.0, Vector2(1, 0)], [5.0, Vector2(0, -1)], [6.5, Vector2.ZERO], [8.0, null]]
var pops := 0
func _initialize() -> void:
	var main: Node3D = load("res://scenes/main.tscn").instantiate()
	root.add_child(main)
	await process_frame
	player = main.find_children("*", "Player", true, false)[0]
	Input.mouse_mode = Input.MOUSE_MODE_VISIBLE
	player.character.wants_to_strafe = false
	sk = Mannequin.find_skeleton(player.visual)
	player.scripted_input = Vector2.ZERO
	physics_frame.connect(_s)
func _s() -> void:
	t += 1.0 / 60.0
	var inp = inputs[0][1]
	for i in inputs:
		if t >= i[0]:
			inp = i[1]
	if inp == null:
		print("POPS total=%d" % pops)
		quit()
		return
	player.scripted_input = inp
	var now := []
	for b in sk.get_bone_count():
		now.append(sk.get_bone_global_pose(b).origin)
	if prev.size() == now.size():
		var worst := 0.0
		var wb := 0
		for b in now.size():
			var d: float = (now[b] - prev[b]).length()
			if d > worst:
				worst = d
				wb = b
		if worst > 0.08:
			pops += 1
			var pl: Array = player.matcher.blend.get_players()
			print("POP t=%.2f bone=%s moved=%.2f m players=%s" % [t, sk.get_bone_name(wb), worst, pl.map(func(x): return "%s@%.2f w%.2f" % [str(x[0]).get_file(), x[1], x[2]])])
	prev = now
