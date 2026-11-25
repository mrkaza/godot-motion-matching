# godot --headless --fixed-fps 60 --path . --script res://tools/checks/test_physical_animation.gd
# The default PhysicalAnimation profile in plain locomotion and under a bump: per phase, how far
# the simulated bodies are from the animated pose (mean / max cm, feet separately) and how much they
# jitter (RMS of the bodies' frame-to-frame acceleration minus the animation's, mm per frame^2).
# Then a bump (no knock-down) from the side: an impulse at the chest on the simulated bodies; peak
# chest and head offsets and the recovery time.
extends SceneTree

const RAGDOLL := preload("res://scripts/ragdoll/ragdoll_component.gd")
const DT := 1.0 / 60.0
const BUMP := 96.0  # kg m/s: 4 kg at 12 m/s bouncing back

var player: Player
var rag
var t := 0.0
var phases := [
	[0.0, "idle", Vector2.ZERO], [1.5, "run", Vector2(0, 1)], [4.0, "turn 90", Vector2(1, 0)],
	[5.5, "turn 180", Vector2(-1, 0)], [7.0, "stop", Vector2.ZERO], [9.0, "bump", Vector2.ZERO], [12.0, "end", Vector2.ZERO],
]
var stats := {}
var hist := []   # last two frames: [bodies, animated]
var phase_name := ""
var bump := {"pushed": false, "peak_chest": 0.0, "peak_head": 0.0, "hit_at": -1.0, "back_at": -1.0}


func _initialize() -> void:
	var world := Node3D.new()
	root.add_child(world)
	current_scene = world
	var ground := StaticBody3D.new()
	ground.position = Vector3(0, -0.5, 0)
	var shape := CollisionShape3D.new()
	shape.shape = BoxShape3D.new()
	(shape.shape as BoxShape3D).size = Vector3(400, 1, 400)
	ground.add_child(shape)
	world.add_child(ground)
	player = Player.new()
	world.add_child(player)
	await process_frame
	Input.mouse_mode = Input.MOUSE_MODE_VISIBLE
	player.character.wants_to_strafe = false
	rag = RAGDOLL.new()
	rag.default_profile = "PhysicalAnimation"  # RagdollLevel's character; the default is Kinematic
	player.add_component(rag)
	player.scripted_input = Vector2.ZERO
	physics_frame.connect(_step)


func _step() -> void:
	t += DT
	var ph: Array = phases[0]
	for p in phases:
		if t >= p[0]:
			ph = p
	if ph[1] == "end":
		_report()
		quit()
		return
	if ph[1] != phase_name:
		phase_name = ph[1]
		stats[phase_name] = {"n": 0, "err": 0.0, "max": 0.0, "feet": 0.0, "jit": 0.0, "jn": 0}
	player.scripted_input = ph[2]
	if not rag.body.simulating or rag.mode != RAGDOLL.Mode.OFF:
		return
	var bodies := []
	var anim := []
	var s: Dictionary = stats[phase_name]
	# The controls' targets: the animated pose on the clip skeleton the bodies simulate.
	var targets: Array = rag._animated_targets()[0]
	for i in rag.body.bodies.size():
		var b: Vector3 = rag.body.bone_world(i).origin
		var a: Vector3 = (targets[i] as Transform3D).origin
		bodies.append(b)
		anim.append(a)
		var e := b.distance_to(a) * 100.0
		s["per"] = s.get("per", {})
		s["per"][rag.body.names[i]] = s["per"].get(rag.body.names[i], 0.0) + e
		s["err"] += e
		s["n"] += 1
		if e > s["max"]:
			s["max"] = e
			s["worst"] = "%s @%.2f" % [rag.body.names[i], t]
		if rag.body.is_foot[i]:
			s["feet"] = maxf(s["feet"], e)
	hist.append([bodies, anim])
	if hist.size() > 3:
		hist.pop_front()
	if hist.size() == 3:
		for i in bodies.size():
			var jb: Vector3 = hist[2][0][i] - 2.0 * hist[1][0][i] + hist[0][0][i]
			var ja: Vector3 = hist[2][1][i] - 2.0 * hist[1][1][i] + hist[0][1][i]
			s["jit"] += (jb - ja).length_squared() * 1e6
			s["jn"] += 1
	if phase_name == "bump":
		if not bump["pushed"] and t >= 9.3:
			rag.push(Vector3(-1, 0, 0) * BUMP, player.character.global_position + Vector3.UP * 1.25)
			bump["pushed"] = true
		var chest: float = bodies[rag.body.names.find("spine_05")].distance_to(anim[rag.body.names.find("spine_05")]) * 100.0
		var head: float = bodies[rag.body.names.find("head")].distance_to(anim[rag.body.names.find("head")]) * 100.0
		bump["peak_chest"] = maxf(bump["peak_chest"], chest)
		bump["peak_head"] = maxf(bump["peak_head"], head)
		if bump["pushed"] and bump["hit_at"] < 0.0 and chest > 5.0:
			bump["hit_at"] = t
		if bump["hit_at"] > 0.0 and bump["back_at"] < 0.0 and chest < 3.0 and t > bump["hit_at"] + 0.1:
			bump["back_at"] = t


func _report() -> void:
	for name: String in stats:
		var s: Dictionary = stats[name]
		if s["n"] == 0:
			continue
		print("%-9s body-anim mean %5.2f cm max %5.2f cm feet max %5.2f cm  jitter %6.3f mm/f^2" % [name, s["err"] / s["n"], s["max"], s["feet"], sqrt(s["jit"] / maxf(s["jn"], 1))], " ", s.get("worst", ""))
	for name: String in ["run", "stop"]:
		var per: Dictionary = stats[name]["per"]
		var keys := per.keys()
		keys.sort_custom(func(a, b): return per[a] > per[b])
		print(name, " worst mean bodies: ", keys.slice(0, 6).map(func(k): return "%s %.1f" % [k, per[k] * 23.0 / stats[name]["n"]]))
	print("bump: peak chest offset %.1f cm, head %.1f cm, back within 3 cm after %.2f s, ragdolled=%s" % [bump["peak_chest"], bump["peak_head"], (bump["back_at"] - bump["hit_at"]) if bump["back_at"] > 0.0 else -1.0, rag.mode == RAGDOLL.Mode.RAGDOLL])
