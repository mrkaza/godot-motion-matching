# godot --headless --fixed-fps 60 --path . --script res://tools/checks/test_foley.gd
# Walk, run, sprint, stops and a jump with the foley component: per phase, footstep events per second
# against what the playing clips' notifies predict (sum over ticks of the active clip's footstep
# notifies per second at its play rate), left/right alternation (a doubled or missing step breaks it),
# the shortest gap between steps, and the jump / land events.
extends SceneTree

const FOOT_TAGS := ["Foley.Event.Walk", "Foley.Event.Run", "Foley.Event.RunBackwds", "Foley.Event.RunStrafe", "Foley.Event.WalkBackwds"]
const SETTLE := 1.2    # seconds skipped at the start of each phase (starts, stops and gait changes)

var player: Player
var foley: Node
var t := 0.0
var step := 0
var phases: Array
var predicted := {}    # phase label -> predicted steps in its steady window
var window := {}       # phase label -> [start, end]
var crossed := {}      # phase label -> footstep notifies the newest player passed in the window
var _top := []         # newest player last tick: [animation, time]


func _initialize() -> void:
	var main: Node3D = load("res://scenes/main.tscn").instantiate()
	root.add_child(main)
	await process_frame
	player = main.find_children("*", "Player", true, false)[0]
	for c in player.components:
		if c.has_method("play_event"):
			foley = c
	if foley == null:
		print("FAIL no foley component")
		quit(1)
		return
	if OS.get_cmdline_user_args().has("sample_filter"):
		foley.filter_inactive_players = true   # the sample's exact notify filter
	print("filter_inactive_players = ", foley.filter_inactive_players)
	Input.mouse_mode = Input.MOUSE_MODE_VISIBLE
	var c := player.character
	c.wants_to_strafe = false
	# An open lane: from z = 8 toward -Z (the obstacles are at z >= 12, the NPC at x = 6).
	c.global_position = Vector3(-3, 0, 8)
	c.yaw = PI
	c.control_yaw = PI
	player.matcher.visual_yaw = PI
	player.camera_yaw = 0.0
	phases = [
		[0.0, "idle", Vector2.ZERO, func(): pass],
		[1.0, "walk", Vector2(0, 1), func(): c.wants_to_walk = true],
		[6.0, "walk stop", Vector2.ZERO, func(): pass],
		[8.0, "run", Vector2(0, 1), func(): c.wants_to_walk = false],
		[13.0, "sprint", Vector2(0, 1), func(): c.wants_to_sprint = true],
		[18.0, "sprint stop", Vector2.ZERO, func(): c.wants_to_sprint = false],
		[20.0, "run again", Vector2(0, 1), func(): pass],
		[22.0, "jump", Vector2(0, 1), func(): player.press_jump()],
		[25.0, "run stop", Vector2.ZERO, func(): pass],
		[27.0, "end", Vector2.ZERO, func(): pass],
	]
	for i in phases.size() - 1:
		window[phases[i][1]] = [minf(phases[i][0] + SETTLE, phases[i + 1][0]), phases[i + 1][0]]
		predicted[phases[i][1]] = 0.0
		crossed[phases[i][1]] = 0
	player.scripted_input = Vector2.ZERO
	physics_frame.connect(_step)


func _step() -> void:
	var dt := 1.0 / 60.0
	t += dt
	while step < phases.size() and t >= phases[step][0]:
		phases[step][3].call()
		player.scripted_input = phases[step][2]
		step += 1
	if step >= phases.size():
		_report()
		quit()
		return
	var trace := _trace_window()
	if (OS.get_cmdline_user_args().has("verbose") and fmod(t, 0.5) < dt) or (t >= trace.x and t <= trace.y):
		var m := player.matcher
		print("t=%5.2f pos=%s spd=%4.0f mode=%s gait=%s players=%s" % [t, player.character.global_position.snappedf(0.01), player.character.speed_2d(), m.vars.get("MovementMode"), m.vars.get("Gait"), m.blend.get_players().map(func(p): return "%s@%.2f w%.2f" % [String(p[0]).get_file(), p[1], p[2]])])
	# Prediction: the active (newest) player's clip, footstep notifies per second at its play rate.
	var label: String = phases[step - 1][1]
	var w: Array = window[label]
	if t >= w[0] and t < w[1]:
		var players: Array = player.matcher.blend.get_players()
		if not players.is_empty():
			var key := ""
			for clip: String in player.matcher.clip_names:
				if player.matcher.clip_names[clip] == players[0][0]:
					key = clip.trim_prefix("res://extracted/anims/").get_basename()
			var anim: Animation = player.matcher.tree.get_animation(players[0][0])
			var n := 0
			for e: Dictionary in foley._notifies.get(key, []):
				if FOOT_TAGS.has(e["tag"]) and e["side"] != "":
					n += 1
			# Clip time advanced this tick (play rate included), as a share of the clip's steps.
			if anim != null and anim.length > 0.0 and _top.size() == 2 and _top[0] == players[0][0]:
				var t0: float = _top[1]
				var t1: float = players[0][1]
				var d: float = t1 - t0
				if d < 0.0:
					d += anim.length
				predicted[label] += d * n / anim.length
				# The newest clip's own footstep notifies passed this tick (no weight or filter rules).
				for e: Dictionary in foley._notifies.get(key, []):
					if FOOT_TAGS.has(e["tag"]) and e["side"] != "":
						var x: float = e["t"]
						if (t1 >= t0 and x > t0 and x <= t1) or (t1 < t0 and (x > t0 or x <= t1)):
							crossed[label] += 1
							if OS.get_cmdline_user_args().has("verbose"):
								var last: Dictionary = foley.events[-1] if not foley.events.is_empty() else {}
								print("  cross t=%.3f %s %s@%.3f w=%.2f  last event %.3f %s %s" % [t, key.get_file(), e["side"], x, players[0][2], last.get("time", -1.0), last.get("clip", "").get_file(), last.get("side", "")])
			_top = [players[0][0], players[0][1]]
	else:
		_top = []


## "trace=a:b" prints the blend stack every tick between a and b seconds.
func _trace_window() -> Vector2:
	for a in OS.get_cmdline_user_args():
		if a.begins_with("trace="):
			var p := a.trim_prefix("trace=").split(":")
			return Vector2(float(p[0]), float(p[1]))
	return Vector2(INF, -INF)


func _report() -> void:
	var ok := true
	print("phase         window        measured/s predicted/s  steps (newest clip's)  alternation  min gap")
	for i in phases.size() - 1:
		var label: String = phases[i][1]
		var w: Array = window[label]
		var steps: Array = foley.events.filter(func(e): return FOOT_TAGS.has(e["tag"]) and e["side"] != "" and e["time"] >= w[0] and e["time"] < w[1])
		var dur: float = w[1] - w[0]
		var breaks := 0
		var min_gap := INF
		for k in range(1, steps.size()):
			if steps[k]["side"] == steps[k - 1]["side"]:
				breaks += 1
			min_gap = minf(min_gap, steps[k]["time"] - steps[k - 1]["time"])
		var meas: float = steps.size() / dur if dur > 0.0 else 0.0
		var pred: float = predicted[label] / dur if dur > 0.0 else 0.0
		print("%-12s %5.1f-%5.1f   %8.2f   %8.2f    %4d (%4d)        %3d breaks   %s" % [label, w[0], w[1], meas, pred, steps.size(), crossed[label], breaks, ("%.3f s" % min_gap) if min_gap < INF else "-"])
		# Steady gaits: the rate must match the clips' notifies; every phase: no doubled or missing step
		# (left/right alternate, no two steps closer than 0.15 s) and nothing the newest clip passed is lost.
		var steady: bool = ["walk", "run", "sprint"].has(label)
		if (steady and absf(meas - pred) > 0.15 * pred) or breaks > 0 or (steps.size() > 1 and min_gap < 0.15) or steps.size() < crossed[label]:
			ok = false
			print("  ^ mismatch")
	var counts := {}
	for e: Dictionary in foley.events:
		var k: String = "%s %s" % [e["source"], e["tag"].trim_prefix("Foley.Event.")]
		counts[k] = counts.get(k, 0) + 1
	print("events by source: ", counts)
	var jumps: Array = foley.events.filter(func(e): return e["source"] == "jump")
	var lands: Array = foley.events.filter(func(e): return e["source"] == "land")
	print("jump events %d at %s, land events %d at %s" % [jumps.size(), jumps.map(func(e): return snappedf(e["time"], 0.01)), lands.size(), lands.map(func(e): return "%.2f vol %.2f" % [e["time"], e["volume"]])])
	if jumps.size() != 1 or lands.size() != 1:
		ok = false
	print("FOLEY TEST ", "PASS" if ok else "FAIL")
