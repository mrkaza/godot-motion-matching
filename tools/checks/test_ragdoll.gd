# godot --headless --fixed-fps 60 --path . --script res://tools/checks/test_ragdoll.gd
# 20 shoves/hits from different directions and strengths, idle and running, on flat ground. Per trial:
# time to settle, face up/down at exit, the get-up picked (and its start time), max joint limit
# overshoot, fastest body (explosion > 30 m/s), whether it ends standing with the pelvis within 5 cm of
# the capsule, and the largest one-frame pelvis jump while the get-up blends in from the physics pose.
extends SceneTree

const RAGDOLL := preload("res://scripts/ragdoll/ragdoll_component.gd")
const DT := 1.0 / 60.0
const EXPLOSION_SPEED := 30.0
const TRIAL_TIMEOUT := 25.0

var player: Player
var rag
var trials: Array = []
var trial := -1
var phase := ""
var t := 0.0
var stats := {}
var results: Array = []
var _last_pelvis := Vector3.INF


func _initialize() -> void:
	var world := Node3D.new()
	root.add_child(world)
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
	rag = RAGDOLL.new()
	player.add_component(rag)
	player.scripted_input = Vector2.ZERO
	# [running, direction (deg, world yaw the push goes toward), strength (kg m/s), height (m), exit]
	for i in 20:
		var running := i % 2 == 1
		var dir := fposmod(i * 137.5, 360.0)
		var strength := 60.0 + float((i * 7) % 20) / 19.0 * 260.0
		var height: float = [1.3, 1.0, 1.5, 0.9][i % 4]
		var exit := "jump" if i % 7 == 3 else ("key" if i == 0 else "auto")
		trials.append([running, dir, strength, height, exit])
	_next_trial()
	physics_frame.connect(_step)


func _next_trial() -> void:
	trial += 1
	if trial >= trials.size():
		_report()
		quit()
		return
	if player.character.global_position.length() > 40.0:
		player.character.global_position = Vector3.ZERO
	phase = "prep"
	t = 0.0
	stats = {"violation": 0.0, "speed": 0.0, "pop": 0.0, "settle": -1.0, "ragdoll": 0.0}
	player.scripted_input = Vector2(0, 1) if trials[trial][0] else Vector2.ZERO


func _step() -> void:
	t += DT
	var tr: Array = trials[trial]
	match phase:
		"prep":
			if t >= (1.5 if tr[0] else 1.0):
				var dir := Vector3(sin(deg_to_rad(tr[1])), 0.0, cos(deg_to_rad(tr[1])))
				var at: Vector3 = player.character.global_position + Vector3.UP * float(tr[3])
				if tr[4] == "key":
					var ev := InputEventKey.new()
					ev.physical_keycode = KEY_R
					ev.pressed = true
					rag.on_key(ev)
					rag.start_ragdoll(dir * tr[2] * 0.5, at)
				else:
					rag.start_ragdoll(dir * tr[2], at)
				player.scripted_input = Vector2.ZERO
				phase = "ragdoll"
				t = 0.0
		"ragdoll":
			if rag.mode == RAGDOLL.Mode.RAGDOLL:
				var viol: float = rag.body.max_limit_violation()
				if viol > stats["violation"]:
					stats["violation"] = viol
					stats["worst"] = "%s @%.2fs" % [rag.body.worst_joint, t]
				stats["speed"] = maxf(stats["speed"], rag.body.max_speed())
				stats["spin"] = maxf(stats.get("spin", 0.0), rag.body.max_spin())
				if rag.speed > RAGDOLL.SETTLE_SPEED:
					stats["still_from"] = t + DT
				if tr[4] == "jump" and t >= 0.6 and rag.has_floor:
					player.press_jump()
				elif tr[4] == "key" and t >= 4.0 and rag.has_floor:
					var ev := InputEventKey.new()
					ev.physical_keycode = KEY_R
					ev.pressed = true
					rag.on_key(ev)
			if rag.mode != RAGDOLL.Mode.RAGDOLL:
				stats["settle"] = stats.get("still_from", 0.0)
				stats["ragdoll"] = t
				phase = "getup"
				t = 0.0
				_last_pelvis = Vector3.INF
			elif t > TRIAL_TIMEOUT:
				_finish(false, "never got up")
		"getup":
			var pelvis := _visible_pelvis()
			if t < 0.6 and _last_pelvis.is_finite():
				stats["pop"] = maxf(stats["pop"], pelvis.distance_to(_last_pelvis))
			_last_pelvis = pelvis
			if rag.mode == RAGDOLL.Mode.OFF and player.matcher.action_clip == "":
				phase = "stand"
				t = 0.0
			elif t > TRIAL_TIMEOUT:
				_finish(false, "get-up never ended")
		"stand":
			if t >= 1.5:
				_finish(true, "")


## Pelvis as drawn: the animation under the snapshot modifier at its influence.
func _visible_pelvis() -> Vector3:
	var sk: Skeleton3D = rag.skeleton
	var anim := sk.get_bone_global_pose(sk.find_bone("pelvis"))
	var snap: SkeletonModifier3D = rag.snapshot
	if snap.active and snap.poses.size() == sk.get_bone_count():
		var root_i := sk.find_bone("root")
		var s := (snap.poses[root_i] as Transform3D) * (snap.poses[sk.find_bone("pelvis")] as Transform3D)
		anim = anim.interpolate_with(s, snap.influence)
	return (sk.global_transform * anim).origin


func _bone_world(bone: String) -> Transform3D:
	var sk: Skeleton3D = rag.skeleton
	return sk.global_transform * sk.get_bone_global_pose(sk.find_bone(bone))


func _finish(ok: bool, why: String) -> void:
	var c := player.character
	var head_h := _bone_world("head").origin.y - c.global_position.y
	var pelvis := _bone_world("pelvis").origin
	var off := Vector2(pelvis.x - c.global_position.x, pelvis.z - c.global_position.z).length()
	var standing: bool = ok and head_h > 1.4 and c.is_on_floor() and rag.mode == RAGDOLL.Mode.OFF
	var g: Dictionary = rag.last_getup
	var tr: Array = trials[trial]
	var res := {
		"i": trial, "run": tr[0], "dir": tr[1], "str": tr[2], "exit": tr[4],
		"settle": stats["settle"], "ragdoll": stats["ragdoll"],
		"face": ("up" if g.get("face_up", false) else "down") if not g.is_empty() else "-",
		"clip": g.get("montage", "none"), "start": g.get("time", -1.0), "rolling": g.get("rolling", false),
		"violation": stats["violation"], "speed": stats["speed"], "pop": stats["pop"] * 100.0,
		"standing": standing, "offset": off * 100.0, "head": head_h, "why": why,
		"explode": stats["speed"] > EXPLOSION_SPEED, "worst": stats.get("worst", ""),
	}
	results.append(res)
	print("trial %2d %-4s dir %5.1f str %5.1f exit %-4s | settle %5.2f s ragdoll %5.2f s | face %-4s %-28s @%.2f roll=%s | limit %5.1f deg vmax %5.1f m/s pop %4.1f cm | stand=%s off %4.1f cm head %.2f %s | %s" % [
		trial, "run" if tr[0] else "idle", tr[1], tr[2], tr[4], res["settle"], res["ragdoll"], res["face"], res["clip"],
		res["start"], res["rolling"], res["violation"], res["speed"], res["pop"], standing, res["offset"], head_h, why, ("spin %.0f " % stats.get("spin", 0.0) + res["worst"]) if OS.has_environment("RAG_DEBUG") else ""])
	_next_trial()


func _report() -> void:
	var standing := results.filter(func(r): return r["standing"] and r["offset"] <= 5.0).size()
	var exploded := results.filter(func(r): return r["explode"]).size()
	var clips := {}
	for r in results:
		clips[r["clip"]] = clips.get(r["clip"], 0) + 1
	var worst := 0.0
	var vmax := 0.0
	var pop := 0.0
	for r in results:
		worst = maxf(worst, r["violation"])
		vmax = maxf(vmax, r["speed"])
		pop = maxf(pop, r["pop"])
	print("SUMMARY standing within 5 cm: %d/%d  explosions: %d  worst limit overshoot %.1f deg  fastest body %.1f m/s  worst get-up pop %.1f cm/frame  clips %s" % [standing, results.size(), exploded, worst, vmax, pop, clips])
