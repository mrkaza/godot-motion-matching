# godot --headless --fixed-fps 60 --path . --script res://tools/checks/test_interactions.gd
# Paired interactions between the player and an NPC on flat ground: shoves from idle and walk,
# tackles at run and sprint, takedowns standing / walking / running, with the victim facing the
# attacker, away, and to either side. Per trial: the asset picked (right type for the speed), the
# alignment error at the end of the attacker's warp window (victim relative to attacker vs the
# asset's placement: cm and degrees), whether both end standing, and the fastest body (explosion
# > 30 m/s).
extends SceneTree

const RAGDOLL := preload("res://scripts/ragdoll/ragdoll_component.gd")
const INTERACT := preload("res://scripts/interactions/interaction_component.gd")
const DT := 1.0 / 60.0
const TIMEOUT := 22.0

var attacker: Player
var victim: Player
var a_int
var v_int
var a_rag
var v_rag
# [type, gait, victim facing (deg, 0 = facing the attacker), expected asset substring]
var trials := []
var trial := -1
var phase := ""
var t := 0.0
var stats := {}
var results := []


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
	attacker = Player.new()
	world.add_child(attacker)
	victim = Player.new()
	victim.is_npc = true
	victim.position = Vector3(0, 0, 30)
	world.add_child(victim)
	await process_frame
	Input.mouse_mode = Input.MOUSE_MODE_VISIBLE
	a_rag = RAGDOLL.new()
	attacker.add_component(a_rag)
	a_int = INTERACT.new()
	attacker.add_component(a_int)
	v_rag = RAGDOLL.new()
	victim.add_component(v_rag)
	v_int = INTERACT.new()
	victim.add_component(v_int)
	attacker.scripted_input = Vector2.ZERO
	victim.scripted_input = Vector2.ZERO
	for facing in [0.0, 180.0, 90.0, -90.0]:
		trials.append(["Shove", "idle", facing, "shove_stand"])
	# Walking is exactly 200 cm/s: both the shove (0-200) and tackle (200+) rows match (ranges are
	# inclusive), both databases are searched, and the closer placement wins.
	for facing in [0.0, 180.0, 90.0]:
		trials.append(["Shove", "walk", facing, "shove_stand|tackle"])
	for facing in [0.0, 180.0, 90.0, -90.0]:
		trials.append(["Shove", "run", facing, "tackle"])
	for facing in [0.0, 180.0]:
		trials.append(["Shove", "sprint", facing, "tackle"])
	for facing in [0.0, 180.0, 90.0, -90.0]:
		trials.append(["Takedown", "idle", facing, "takedown_stand"])
	for facing in [0.0, 90.0]:
		trials.append(["Takedown", "walk", facing, "takedown_Walk"])
	for facing in [180.0, -90.0]:
		trials.append(["Takedown", "run", facing, "takedown_Run"])
	_next()
	physics_frame.connect(_step)


func _place(p: Player, pos: Vector3, yaw: float) -> void:
	p.character.global_position = pos
	p.character.yaw = yaw
	p.character.velocity_cm = Vector3.ZERO
	p.character.velocity = Vector3.ZERO
	p.matcher.visual_yaw = yaw
	p.visual.global_position = pos
	p.visual.global_basis = Basis(Vector3.UP, yaw)


func _next() -> void:
	trial += 1
	if trial >= trials.size():
		_report()
		quit()
		return
	var tr: Array = trials[trial]
	var gait: String = tr[1]
	var start := {"idle": 1.1, "walk": 4.0, "run": 9.0, "sprint": 12.0}[gait] as float
	if tr[0] == "Takedown" and gait == "idle":
		start = 1.3
	# The victim stands at the origin; the attacker comes from -Z, facing +Z.
	_place(victim, Vector3.ZERO, PI + deg_to_rad(tr[2]))
	_place(attacker, Vector3(0, 0, -start), 0.0)
	attacker.character.wants_to_strafe = false
	attacker.character.wants_to_walk = gait == "walk"
	attacker.character.wants_to_sprint = gait == "sprint"
	attacker.scripted_input = Vector2.ZERO if gait == "idle" else Vector2(0, 1)
	phase = "approach"
	t = 0.0
	stats = {"speed": 0.0, "align_cm": -1.0, "align_deg": -1.0, "asset": "", "measured": false}


func _step() -> void:
	t += DT
	var tr: Array = trials[trial]
	stats["speed"] = maxf(stats["speed"], maxf(a_rag.body.max_speed(), v_rag.body.max_speed()))
	match phase:
		"approach":
			var d: float = attacker.character.global_position.distance_to(victim.character.global_position)
			var trigger: float = 1.1 if tr[1] == "idle" else (1.5 if tr[1] == "walk" else 1.95)
			if tr[0] == "Takedown" and tr[1] == "idle":
				trigger = 1.3
			if (d <= trigger and t > 0.4) or (tr[1] == "idle" and t > 0.5):
				var r: Dictionary = a_int.try_interaction(tr[0])
				if r.is_empty() and t < 6.0 and tr[1] != "idle":
					return
				attacker.scripted_input = Vector2.ZERO
				if r.is_empty():
					_finish("no interaction (speed %.0f, dist %.2f)" % [attacker.character.speed_2d(), d])
					return
				stats["asset"] = String(r["asset"]).get_file().trim_prefix("PSIA_M_relaxed_")
				stats["speed_at"] = r["speed"]
				stats["result"] = r
				phase = "play"
				t = 0.0
			elif t > 8.0:
				_finish("never reached")
		"play":
			var r: Dictionary = stats["result"]
			var wins: Array = r["infos"]["Attacker"]["windows"]
			if not stats["measured"] and not wins.is_empty() and a_int.role == INTERACT.Role.ATTACKER \
					and a_int.montage_time >= wins[0]["end"] - 1e-3 and (v_int.role == INTERACT.Role.VICTIM or v_rag.is_ragdoll()):
				var want: Array = a_int.expected_relative(r, a_int.montage_time)
				var got: Array = INTERACT.actual_relative(a_int, v_int)
				var dw: Vector3 = want[0] - got[0]
				stats["align_cm"] = Vector2(dw.x, dw.z).length() * 100.0
				stats["align_deg"] = absf(rad_to_deg(wrapf(want[1] - got[1], -PI, PI)))
				stats["measured"] = true
			if t > 1.0 and not a_int.is_busy() and not v_int.is_busy() and a_rag.mode == RAGDOLL.Mode.OFF and v_rag.mode == RAGDOLL.Mode.OFF:
				phase = "settle"
				t = 0.0
			elif t > TIMEOUT:
				_finish("did not end")
		"settle":
			if t >= 1.0:
				_finish("")


func _standing(p: Player) -> bool:
	var sk := Mannequin.find_skeleton(p.visual)
	var head := (sk.global_transform * sk.get_bone_global_pose(sk.find_bone("head"))).origin
	return head.y - p.character.global_position.y > 1.4 and p.matcher_enabled


func _finish(why: String) -> void:
	var tr: Array = trials[trial]
	var ok_type := false
	for want: String in String(tr[3]).split("|"):
		ok_type = ok_type or String(stats["asset"]).to_lower().contains(want.to_lower())
	var res := {"type_ok": ok_type, "standing": why == "" and _standing(attacker) and _standing(victim),
		"explode": stats["speed"] > 30.0, "align_cm": stats["align_cm"], "align_deg": stats["align_deg"]}
	results.append(res)
	print("trial %2d %-8s %-6s facing %4.0f | %-28s speed %4.0f type_ok=%s | align %5.1f cm %5.1f deg | standing=%s vmax %4.1f m/s %s" % [
		trial, tr[0], tr[1], tr[2], stats["asset"], stats.get("speed_at", 0.0), ok_type, stats["align_cm"], stats["align_deg"],
		res["standing"], stats["speed"], why])
	_next()


func _report() -> void:
	var ok := results.filter(func(r): return r["type_ok"]).size()
	var stand := results.filter(func(r): return r["standing"]).size()
	var boom := results.filter(func(r): return r["explode"]).size()
	var cm := 0.0
	var deg := 0.0
	for r in results:
		cm = maxf(cm, r["align_cm"])
		deg = maxf(deg, r["align_deg"])
	print("SUMMARY right type %d/%d  both standing %d/%d  explosions %d  worst alignment %.1f cm %.1f deg" % [ok, results.size(), stand, results.size(), boom, cm, deg])
