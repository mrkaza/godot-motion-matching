# godot --headless --fixed-fps 60 --path . --script res://tools/checks/test_ragdoll_bend.gd
# How far the joints bend away from what the muscles pull toward ("the ragdoll bends too much" as a
# number). Per scenario, a fresh character on flat ground:
#   fall   R while standing: active ragdoll from the idle pose (no push), 4 s
#   hit    a 144 kg m/s hit at the chest from the side while standing, 4 s
#   shove  a 250 kg m/s push at the chest from behind, 4 s
#   bump   a 96 kg m/s push at the chest from the side in the PhysicalAnimation profile (RagdollLevel)
#          without ragdolling, 2 s
# Per body every tick: the angle between its rotation relative to its parent body and the parent-space
# target of the last drive (ragdoll_body.gd last_rel_target: the ABP ragdoll pose, or the animation in
# PhysicalAnimation). Reported per limb (mean / 95th percentile / max degrees) for the whole window and
# for the "rest" part (last 1.5 s of the ragdoll scenarios, the body lying still: what gravity alone
# bends against the muscles), plus the whole-body mean. bump also reports the bodies' world rotation
# error against the animation (the world-space controls).
extends SceneTree

const RAGDOLL := preload("res://scripts/ragdoll/ragdoll_component.gd")
const DT := 1.0 / 60.0
const LIMB_NAMES := ["head", "torso", "arms", "legs"]
const SCENARIOS := [["fall", 4.0], ["hit", 4.0], ["shove", 4.0], ["bump", 2.0]]
const SIDE := Vector3(-1, 0, -0.2)  # hit and bump direction

var world: Node3D
var player: Player
var rag
var scenario := -1
var t := 0.0
var started := -1.0
var samples := {}     # window -> limb -> PackedFloat32Array of degrees
var world_err := PackedFloat32Array()
var summary := []
var per_body := {}    # body name -> [sum degrees, count] over the rest window


func _initialize() -> void:
	world = Node3D.new()
	root.add_child(world)
	current_scene = world
	var ground := StaticBody3D.new()
	ground.position = Vector3(0, -0.5, 0)
	var shape := CollisionShape3D.new()
	shape.shape = BoxShape3D.new()
	(shape.shape as BoxShape3D).size = Vector3(400, 1, 400)
	ground.add_child(shape)
	world.add_child(ground)
	physics_frame.connect(_step)
	_next()


func _next() -> void:
	if player != null:
		player.queue_free()
		player = null
		await process_frame
	scenario += 1
	if scenario >= SCENARIOS.size():
		print("SUMMARY ", " | ".join(summary))
		quit()
		return
	player = Player.new()
	world.add_child(player)
	await process_frame
	Input.mouse_mode = Input.MOUSE_MODE_VISIBLE
	player.character.wants_to_strafe = false
	rag = RAGDOLL.new()
	rag.auto_getup = false
	rag.default_profile = "PhysicalAnimation"  # the bump scenario is RagdollLevel's character
	player.add_component(rag)
	player.scripted_input = Vector2.ZERO
	t = 0.0
	started = -1.0
	samples = {"all": {}, "rest": {}}
	world_err = PackedFloat32Array()
	per_body = {}


func _step() -> void:
	if player == null or rag == null or rag.body == null:
		return
	t += DT
	var name: String = SCENARIOS[scenario][0]
	var length: float = SCENARIOS[scenario][1]
	if started < 0.0:
		if t >= 1.0:
			match name:
				"fall":
					rag.trigger_ragdoll()
				"hit":
					rag.start_ragdoll(SIDE.normalized() * 144.0, player.character.global_position + Vector3.UP * 1.25)
				"shove":
					rag.start_ragdoll(Vector3(0, 0, 1).rotated(Vector3.UP, player.character.yaw) * 250.0, player.character.global_position + Vector3.UP * 1.3)
				"bump":
					rag.push(SIDE.normalized() * 96.0, player.character.global_position + Vector3.UP * 1.25)
			started = t
		return
	var since := t - started
	var ragdoll_scenario := name != "bump"
	if ragdoll_scenario and rag.mode != RAGDOLL.Mode.RAGDOLL:
		return
	if since > (length + (2.0 if name == "hit" else 0.0)):
		_report(name, ragdoll_scenario)
		_next()
		return
	var b = rag.body
	if OS.has_environment("BEND_TRACE") and int(round(since * 60.0)) % 30 == 0:
		_trace(b, OS.get_environment("BEND_TRACE"), since)
	for i in b.bodies.size():
		var e: float = b.bend_error(i)
		if e < 0.0:
			continue
		var deg := rad_to_deg(e)
		_add("all", b.limb[i], deg)
		if ragdoll_scenario and rag.time_in_mode > length - 1.5:
			_add("rest", b.limb[i], deg)
			var pb: Array = per_body.get(b.names[i], [0.0, 0])
			per_body[b.names[i]] = [pb[0] + deg, pb[1] + 1]
		if not ragdoll_scenario and b._prev_world.size() == b.bodies.size():
			var target: Quaternion = (b._prev_world[i] as Transform3D).basis.get_rotation_quaternion()
			var q: Quaternion = b.state(i).transform.basis.get_rotation_quaternion()
			world_err.append(rad_to_deg(b._axis_angle(target.inverse() * q).length()))


## BEND_TRACE=<body> prints that joint's target and actual angles (twist, swing Y, swing Z), the limits
## as set and the strength every 0.5 s.
func _trace(b, body_name: String, since: float) -> void:
	var i: int = b.names.find(body_name)
	if i < 0 or b.parent[i] < 0 or b.last_rel_target[i] == null:
		return
	var p: int = b.parent[i]
	var rel: Quaternion = b.state(p).transform.basis.get_rotation_quaternion().inverse() * b.state(i).transform.basis.get_rotation_quaternion()
	var deg := func(v: Vector3) -> String: return "(%.0f %.0f %.0f)" % [rad_to_deg(v.x), rad_to_deg(v.y), rad_to_deg(v.z)]
	print("%5.2f %s target %s actual %s limits %s strength %.1f Hz err %.0f" % [since, body_name, deg.call(b.joint_angles(i, b.last_rel_target[i])), deg.call(b.joint_angles(i, rel)), deg.call(b.joint_set_limits[i]), b.last_strength[i], rad_to_deg(b.bend_error(i))])


func _add(window: String, limb: int, deg: float) -> void:
	var w: Dictionary = samples[window]
	var a: PackedFloat32Array = w.get(limb, PackedFloat32Array())
	a.append(deg)
	w[limb] = a  # packed arrays are values


static func _stats(a: PackedFloat32Array) -> Vector3:
	if a.is_empty():
		return Vector3.ZERO
	var s := a.duplicate()
	s.sort()
	var mean := 0.0
	for v in s:
		mean += v
	return Vector3(mean / s.size(), s[mini(s.size() - 1, int(s.size() * 0.95))], s[-1])


func _report(name: String, ragdoll_scenario: bool) -> void:
	for window: String in (["all", "rest"] if ragdoll_scenario else ["all"]):
		var w: Dictionary = samples[window]
		var line := "%-6s %-4s" % [name, window]
		var everything := PackedFloat32Array()
		for limb in 4:
			var a: PackedFloat32Array = w.get(limb, PackedFloat32Array())
			everything.append_array(a)
			var st := _stats(a)
			line += " | %-5s mean %5.1f p95 %5.1f max %5.1f" % [LIMB_NAMES[limb], st.x, st.y, st.z]
		var all_st := _stats(everything)
		line += " | body mean %5.1f p95 %5.1f deg" % [all_st.x, all_st.y]
		print(line)
		summary.append("%s/%s %.1f" % [name, window, all_st.x])
	if ragdoll_scenario:
		var keys := per_body.keys()
		keys.sort_custom(func(x, y): return per_body[x][0] / per_body[x][1] > per_body[y][0] / per_body[y][1])
		print("%-6s rest worst bodies: %s" % [name, ", ".join(keys.slice(0, 8).map(func(k): return "%s %.0f" % [k, per_body[k][0] / per_body[k][1]]))])
	if not ragdoll_scenario:
		var ws := _stats(world_err)
		print("%-6s world rotation error mean %5.1f p95 %5.1f max %5.1f deg, ragdolled=%s" % [name, ws.x, ws.y, ws.z, rag.mode == RAGDOLL.Mode.RAGDOLL])
		summary.append("%s/world %.1f" % [name, ws.x])
