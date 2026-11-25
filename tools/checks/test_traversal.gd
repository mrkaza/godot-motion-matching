# godot --headless --fixed-fps 60 --path . --script res://tools/checks/test_traversal.gd [-- <case filter>] [trace] [nojt]
# (trace: per-frame log; nojt: without the JustTraversed hook)
# Runs the player into boxes of the sample's traversal heights at stand / walk / run and reports per
# case: the action and montage the sample's logic picks (and the expected one), the start time, how
# deep the capsule and the skeleton's bones get into the box, how far the attach bone ends from the
# ledge at the end of the FrontLedge warp, the planted-foot slide in the first 0.5 s after the hand-back
# to motion matching, and whether the character ends on top / behind as expected.
# The vault box stands at the edge of a 1.5 m platform: the sample only vaults when there is no floor
# within 50 cm + the capsule half height below the back ledge (a 1 m box on flat ground is a hurdle).
extends SceneTree

const TRAVERSAL := preload("res://scripts/traversal/traversal_component.gd")
const DT := 1.0 / 60.0
const RUN_UP := 7.0          # m from the box face where walk/run cases start
const PRESS := {"stand": 0.6, "walk": 1.5, "run": 2.5}   # root-to-face distance when jump is pressed
const AFTER := 0.5           # s measured after the hand-back
const PLANTED := 0.035       # a foot (ball) this close to the support surface counts as planted (rests at ~2 cm)
const LIMIT_PEN := 0.05
const LIMIT_SLIDE := 0.5

# name, box height, box depth, platform height under the box (vault), expected action, montage part, end
const BOXES := [
	["baseline", 0.0, 1.0, 0.0, "None", "-", "front"],         # steady locomotion, no box
	["baseline start", -1.0, 1.0, 0.0, "None", "-", "front"],  # first 0.5 s of a start from standing
	["hurdle 0.9", 0.9, 0.3, 0.0, "Hurdle", "Hurdle", "behind"],
	["box 1.0x0.4", 1.0, 0.4, 0.0, "Hurdle", "Hurdle", "behind"],
	["vault 1.0x0.4", 1.0, 0.4, 0.6, "Vault", "Vault", "behind"],
	["mantle 1.2", 1.2, 4.0, 0.0, "Mantle", "Mantle", "top"],
	["mantle 1.5", 1.5, 4.0, 0.0, "Mantle", "Mantle", "top"],
	["climb 2.3", 2.3, 4.0, 0.0, "Mantle", "Climb", "top"],
	["climb 2.7", 2.7, 4.0, 0.0, "Mantle", "Climb", "top"],
]
const SPEEDS := ["stand", "walk", "run"]

var cases := []
var case_index := -1
var world: Node3D
var player: Player
var trav: Node
var box := {}               # center, half (AABB of the obstacle box)
var phase := ""
var t := 0.0
var stats := {}
var rows := []
var filter := ""


func _initialize() -> void:
	for a in OS.get_cmdline_user_args():
		if not a in ["trace", "nojt", "nocont"]:
			filter = a
	for b in BOXES:
		for s in SPEEDS:
			var name := "%s %s" % [b[0], s]
			if filter == "" or filter in name:
				cases.append({"name": name, "box": b, "speed": s})
	await process_frame
	physics_frame.connect(_step)
	_next_case()


func _next_case() -> void:
	case_index += 1
	if world != null:
		world.queue_free()
		world = null
	if case_index >= cases.size():
		_report()
		quit()
		return
	var c: Dictionary = cases[case_index]
	var b: Array = c["box"]
	world = Node3D.new()
	root.add_child(world)
	_static_box(world, Vector3(0, -0.5, 0), Vector3(60, 1, 60))
	var plat: float = b[3]
	var h: float = b[1]
	var depth: float = b[2]
	# The face is at z = 0, the box goes to +z.
	if plat > 0.0:
		_static_box(world, Vector3(0, plat / 2.0, -15.0 + depth), Vector3(4, plat, 30))  # platform ends at the box's back face
	var center := Vector3(0, plat + h / 2.0, depth / 2.0)
	var size := Vector3(3.0, h, depth)
	if h > 0.0:
		_static_box(world, center, size)
	box = {"center": center, "half": size / 2.0, "floor": plat, "top": plat + h}
	player = Player.new()
	world.add_child(player)
	_poses = {}
	player.matcher.skeleton.skeleton_updated.connect(_grab.bind(player.matcher.skeleton))
	trav = TRAVERSAL.new()
	trav.continue_in_from_traversal = not OS.get_cmdline_user_args().has("nocont")
	if not OS.get_cmdline_user_args().has("nojt"):
		player.matcher.traversal = trav  # JustTraversed hook (built into MotionMatcher)
	player.add_component(trav)
	var speed: String = c["speed"]
	var start_z: float = -PRESS["stand"] if speed == "stand" else -RUN_UP
	player.character.global_position = Vector3(0, plat, start_z)
	player.camera_yaw = -PI           # forward (+z) is the camera's forward
	player.character.yaw = 0.0
	player.character.control_yaw = 0.0
	player.matcher.visual_yaw = 0.0
	player.character.wants_to_walk = speed == "walk"
	player.scripted_input = Vector2.ZERO
	phase = "settle"
	t = 0.0
	stats = {"name": c["name"], "expect": b[4], "expect_montage": b[5], "expect_end": b[6], "action": "-", "montage": "-",
		"start": -1.0, "cap_pen": 0.0, "bone_pen": 0.0, "bone_pen_name": "", "cap_info": "", "attach_err": -1.0, "slide": [], "slide_max": 0.0,
		"end": "-", "speed_at_press": 0.0, "step": "", "height": 0.0, "depth": 0.0, "blend_out": -1.0}
	trav.traversal_started.connect(_on_started)
	trav.traversal_finished.connect(_on_finished)


func _static_box(parent: Node3D, center: Vector3, size: Vector3) -> void:
	var body := StaticBody3D.new()
	body.position = center
	var shape := CollisionShape3D.new()
	shape.shape = BoxShape3D.new()
	(shape.shape as BoxShape3D).size = size
	body.add_child(shape)
	parent.add_child(body)


func _on_started(r: Dictionary) -> void:
	stats["action"] = trav.ACTION_NAMES[r["action"]]
	stats["montage"] = String(r["montage"]).get_file().replace("AM_M_Neutral_Traversal_", "")
	stats["start"] = r["start_time"]
	if OS.get_cmdline_user_args().has("trace"):
		for w: Dictionary in trav.montage["windows"]:
			print("  window %s %.3f-%.3f contact=%.3f" % [w["target"], w["start"], w["end"], w.get("contact", -1.0)])
	stats["speed_at_press"] = player.character.speed_2d()
	stats["height"] = r["obstacle_height"]
	stats["depth"] = r["obstacle_depth"]


func _on_finished(r: Dictionary) -> void:
	stats["blend_out"] = r.get("blend_out_time", -1.0)
	phase = "after"
	t = 0.0


func _step() -> void:
	if world == null or player == null or not player.is_inside_tree():
		return
	t += DT
	var c: Dictionary = cases[case_index]
	var speed: String = c["speed"]
	var face_dist := -player.character.global_position.z
	match phase:
		"settle":
			if t >= 0.5:
				phase = "approach"
				t = 0.0
		"approach":
			player.scripted_input = Vector2.ZERO if speed == "stand" else Vector2(0, 1)
			if c["box"][1] <= 0.0:
				# Baseline: plain locomotion, the same foot-slide measure without a traversal.
				if t >= (2.0 if c["box"][1] == 0.0 else 0.0):
					stats["action"] = "None"
					phase = "after"
					t = 0.0
				return
			if face_dist <= PRESS[speed] + 1e-3 or speed == "stand":
				player.press_jump()
				if not trav.doing_traversal:
					stats["step"] = "%s (h %.0f d %.0f)" % [trav.result.get("step", "?"), trav.result.get("obstacle_height", 0.0), trav.result.get("obstacle_depth", 0.0)]
					stats["action"] = "none"
					_finish_case()
					return
				phase = "traversing"
				t = 0.0
		"traversing":
			if OS.get_cmdline_user_args().has("trace"):
				var sk := player.matcher.skeleton
				var hr := (sk.global_transform * _drawn(sk, sk.find_bone("ring_03_r"))).origin
				var hl := (sk.global_transform * _drawn(sk, sk.find_bone("hand_l"))).origin
				var at := (sk.global_transform * _drawn(sk, maxi(sk.find_bone("attach"), 0))).origin
				var p := player.character.global_position
				print("  t=%.3f root=(%.3f %.3f) ring_r=(%.3f %.3f) hand_l=(%.3f %.3f) attach=(%.3f %.3f) yaw=%.1f" % [trav.montage_time, p.y, p.z, hr.y, hr.z, hl.y, hl.z, at.y, at.z, rad_to_deg(player.character.yaw)])
			_measure_penetration()
			_measure_attach()
			if t > 8.0:
				stats["step"] = "timeout"
				_finish_case()
		"after":
			if player.character.movement_mode != GaspCharacter.MovementMode.ON_GROUND and not stats.has("landed"):
				t = 0.0   # an airborne hand-back (vault) is measured from the landing
				return
			stats["landed"] = true
			if OS.get_cmdline_user_args().has("trace"):
				var m := player.matcher
				var sk := m.skeleton
				var bl := (sk.global_transform * _drawn(sk, sk.find_bone("ball_l"))).origin
				var br := (sk.global_transform * _drawn(sk, sk.find_bone("ball_r"))).origin
				if OS.has_environment("SLIDE_SOURCE"):
					bl = m._bone_world("ball_l").origin
					br = m._bone_world("ball_r").origin
				var clip := ""
				if m.current_pose >= 0:
					var d: PoseDatabase = m.databases[m.current_db]
					clip = d.entry_clip[d.pose_entry[m.current_pose]].get_file().get_basename() + "@%.2f" % d.pose_time[m.current_pose]
				print("  after t=%.3f v=%.0f ball_l=(%.3f %.3f) ball_r=(%.3f %.3f) players=%d db=%s clip=%s" % [t, player.character.speed_2d(), bl.y, bl.z, br.y, br.z, m.blend.get_player_count(), m.current_db.get_file(), clip])
			_measure_penetration()
			_measure_slide()
			if t >= AFTER:
				_finish_case()


func _finish_case() -> void:
	stats["end"] = _end_state()
	rows.append(stats)
	phase = ""
	_print_row(stats)
	_next_case()


# ------------------------------------------------------------------ measurements

func _box_sdf(p: Vector3) -> float:
	var q: Vector3 = (p - box["center"]).abs() - box["half"]
	var outside := Vector3(maxf(q.x, 0), maxf(q.y, 0), maxf(q.z, 0)).length()
	return outside + minf(maxf(q.x, maxf(q.y, q.z)), 0.0)


func _measure_penetration() -> void:
	if box["half"].y <= 0.0:
		return
	var ch := player.character
	var radius := 0.30
	var a := ch.global_position + Vector3(0, radius, 0)
	var b := ch.global_position + Vector3(0, 1.72 - radius, 0)
	var min_d := INF
	for i in 41:
		min_d = minf(min_d, _box_sdf(a.lerp(b, i / 40.0)))
	if phase == "after":
		stats["cap_pen_after"] = maxf(stats.get("cap_pen_after", 0.0), radius - min_d)
	if radius - min_d > stats["cap_pen"]:
		stats["cap_pen"] = radius - min_d
		var rel: Vector3 = ch.global_position - box["center"]
		stats["cap_info"] = "%s@%.2f root=(y%.2f z%.2f)" % [phase.left(4), trav.montage_time, ch.global_position.y, ch.global_position.z]
	var sk := player.matcher.skeleton
	for bi in sk.get_bone_count():
		if not _is_body_bone(sk.get_bone_name(bi)):
			continue
		var p := (sk.global_transform * _drawn(sk, bi)).origin
		if OS.has_environment("PEN_SOURCE"):  # the clip skeleton's bones, before the retarget and IK
			p = player.matcher._bone_world(sk.get_bone_name(bi)).origin
		var d := -_box_sdf(p)
		if d > stats["bone_pen"]:
			if OS.has_environment("PEN_DEBUG"):
				var bn := sk.get_bone_name(bi)
				var hand := "hand_r" if bn.ends_with("_r") else "hand_l"
				var hd := (sk.global_transform * _drawn(sk, sk.find_bone(hand))).origin
				var hs := player.matcher._bone_world(hand).origin
				print("  pen %s %.3f @%.2f  %s drawn-source=%s (sdf drawn %.3f source %.3f)  curves=%s" % [bn, d, trav.montage_time, hand, hd - hs, _box_sdf(hd), _box_sdf(hs), player.matcher.retarget.chain_curves])
			stats["bone_pen"] = d
			stats["bone_pen_name"] = "%s@%.2f" % [sk.get_bone_name(bi), trav.montage_time]


## Deforming bones only: virtual (VB), IK, prop and marker bones (attach, interaction) carry no mesh.
static func _is_body_bone(name: String) -> bool:
	if name.begins_with("VB ") or name.begins_with("ik_") or name.begins_with("weapon") or "prop" in name:
		return false
	return not name in ["root", "attach", "interaction", "poi", "center_of_mass"]


func _measure_attach() -> void:
	# The attach bone must sit on the front ledge (+0.5 cm) when the last FrontLedge window ends.
	var last_end := -1.0
	for w: Dictionary in trav.montage.get("windows", []):
		if w["target"] == "FrontLedge":
			last_end = maxf(last_end, w["end"])
	if last_end < 0.0 or stats["attach_err"] >= 0.0 or trav.montage_time < last_end:
		return
	var sk := player.matcher.skeleton
	if sk.find_bone("attach") < 0:
		return  # Manny has no attach bone (attach_err stays -1)
	# The skeleton's root stays put (root motion moves the body), so attach is read relative to root.
	var root_xf := sk.global_transform * _drawn(sk, sk.find_bone("root"))
	var attach := sk.global_transform * _drawn(sk, sk.find_bone("attach"))
	var ledge: Vector3 = trav.result["front_ledge"] + Vector3(0, 0.005, 0)
	stats["attach_err"] = (attach.origin - ledge).length()
	stats["attach_vec"] = (attach.origin - ledge)
	stats["root_at_attach"] = root_xf.origin


func _measure_slide() -> void:
	var sk := player.matcher.skeleton
	if not stats.has("_prev_feet"):
		stats["_prev_feet"] = {}
	var speeds := []
	for bone in ["ball_l", "ball_r"]:
		var p := (sk.global_transform * _drawn(sk, sk.find_bone(bone))).origin
		if OS.has_environment("SLIDE_SOURCE"):  # the clip skeleton's feet, before the retarget and foot lock
			p = player.matcher._bone_world(bone).origin
		var prev = stats["_prev_feet"].get(bone)
		stats["_prev_feet"][bone] = p
		if prev == null:
			continue
		var support := _support_height(p)
		if p.y - support > PLANTED:
			continue
		speeds.append(Vector2(p.x - prev.x, p.z - prev.z).length() / DT)
	if speeds.is_empty():
		return
	var s: float = speeds.min()
	stats["slide"].append(s)
	stats["slide_max"] = maxf(stats["slide_max"], s)


func _support_height(p: Vector3) -> float:
	var c: Vector3 = box["center"]
	var hh: Vector3 = box["half"]
	if absf(p.x - c.x) <= hh.x and absf(p.z - c.z) <= hh.z:
		return box["top"]
	if p.z < c.z - hh.z:
		return box["floor"]
	return 0.0 if box["floor"] > 0.0 else box["floor"]


func _end_state() -> String:
	var p := player.character.global_position
	var c: Vector3 = box["center"]
	var hh: Vector3 = box["half"]
	if p.z > c.z + hh.z and p.y < box["top"] - 0.3:
		return "behind"
	if absf(p.z - c.z) <= hh.z and absf(p.y - box["top"]) < 0.1:
		return "top"
	if p.z < c.z - hh.z:
		return "front"
	return "y=%.2f z=%.2f" % [p.y, p.z]


func _print_row(s: Dictionary) -> void:
	var slide: Array = s["slide"]
	var mean := 0.0
	for v in slide:
		mean += v
	mean = mean / slide.size() if slide.size() > 0 else 0.0
	s["slide_mean"] = mean
	var ok_action: bool = s["action"] == s["expect"] and s["expect_montage"] in s["montage"]
	var end_ok: bool = s["end"] == s["expect_end"] or s["expect"] == "None"
	var ok: bool = ok_action and s.get("cap_pen_after", 0.0) <= LIMIT_PEN and s["bone_pen"] <= LIMIT_PEN and mean <= LIMIT_SLIDE and end_ok
	s["ok"] = ok
	print("%-4s %-20s action=%-6s (exp %-6s) montage=%-28s start=%.3f v=%3.0f h=%3.0f d=%3.0f | cap_pen=%.3f %-26s after=%.3f bone_pen=%.3f %-16s attach_err=%.3f | blendout=%.2f slide=%.2f (max %.2f, n=%d) end=%s %s" % [
		"OK" if ok else "FAIL", s["name"], s["action"], s["expect"], s["montage"], s["start"], s["speed_at_press"], s["height"], s["depth"],
		s["cap_pen"], s["cap_info"], s.get("cap_pen_after", 0.0), s["bone_pen"], s["bone_pen_name"], s["attach_err"], s["blend_out"], mean, s["slide_max"], slide.size(), s["end"], s["step"]])


func _report() -> void:
	var passed := rows.filter(func(r): return r["ok"]).size()
	print("TRAVERSAL %d / %d cases pass (action, penetration <= %.2f m, slide <= %.2f m/s, end state)" % [passed, rows.size(), LIMIT_PEN, LIMIT_SLIDE])


# Bones are read as drawn: Godot reports the pose before the skeleton modifiers (retarget, foot
# lock) except while the skeleton updates, so the drawn pose is kept from skeleton_updated.
var _poses := {}


func _grab(sk: Skeleton3D) -> void:
	for i in sk.get_bone_count():
		_poses[i] = sk.get_bone_global_pose(i)


func _drawn(sk: Skeleton3D, bone: int) -> Transform3D:
	return _poses.get(bone, sk.get_bone_global_pose(bone))
