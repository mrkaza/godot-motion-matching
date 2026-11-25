# godot --headless --path . --script res://tools/checks/check_body_cycle.gd
# Presses B four times; prints the body shown on the player and the NPC after each press (the NPC
# stays Manny, shown as an empty name).
extends SceneTree

func _initialize() -> void:
	var main: Node3D = load("res://scenes/main.tscn").instantiate()
	root.add_child(main)
	await process_frame
	var players := main.find_children("*", "Player", true, false)
	var switcher: Node = main.find_children("*", "", true, false).filter(func(n: Node) -> bool: return n.get_script() != null and n.get_script().resource_path.ends_with("body_switcher.gd"))[0]
	var manny_shown := func(p) -> bool: return Mannequin.find_skeleton(p.visual.get_child(0)).get_children().any(func(c): return c is MeshInstance3D and c.visible)
	var shown := func() -> String: return " / ".join(players.map(func(p): return "%s %s" % [p.name, switcher._shown(p).get_file() if switcher._shown(p) != "" else ("Manny" if manny_shown.call(p) else "nothing")]))
	print("start: ", shown.call(), "  button: ", switcher._button.text)
	for i in 4:
		var e := InputEventKey.new()
		e.physical_keycode = KEY_B
		switcher.on_key(e)
		await process_frame
		var springs := players.map(func(p): return p.visual.find_children("Springs", "", true, false).filter(func(s): return s.get_parent().get_parent().visible).size())
		print("B: ", shown.call(), "  button: ", switcher._button.text, "  visible springs: ", springs)
	quit()
