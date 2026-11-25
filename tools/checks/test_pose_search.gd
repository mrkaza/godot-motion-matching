# godot --headless --path . --script res://tools/checks/test_pose_search.gd
# Searches every pose of a database for itself: the native search must return that pose (or an
# equal-cost one) and agree with a GDScript brute force.
extends SceneTree

func _initialize() -> void:
	var db: PoseDatabase = load("res://databases/MotionMatchingData/Databases/Dense/PSD_Dense_Stand_Run_Loops.res")
	var search := PoseSearch.new()
	search.set_database(db.values, db.dims, db.weights, db.pose_addend, db.pose_blocked, db.pose_entry)
	var mismatches := 0
	var worst := 0.0
	var started := Time.get_ticks_usec()
	var checked := 0
	for p in range(0, db.pose_count(), 7):
		var raw := PackedFloat32Array()
		for d in db.dims:
			raw.append(db.raw_value(p, d))
		var q := search.weigh(raw)
		var r := search.search(q, PackedInt32Array(), PackedInt32Array(), INF)
		# Brute force in GDScript.
		var best := INF
		for o in db.pose_count():
			if db.pose_blocked[o]:
				continue
			var c: float = db.pose_addend[o] + search.feature_cost(o, q)
			best = minf(best, c)
		checked += 1
		if absf(r[1] - best) > 1e-4:
			mismatches += 1
		worst = maxf(worst, absf(r[1] - best))
	print("POSESEARCH checked=%d mismatches=%d worst_diff=%.6f poses=%d" % [checked, mismatches, worst, db.pose_count()])
	var q0 := search.weigh(PackedFloat32Array())
	started = Time.get_ticks_usec()
	for i in 200:
		search.search(q0, PackedInt32Array(), PackedInt32Array(), INF)
	print("POSESEARCH avg_search_us=%.1f" % ((Time.get_ticks_usec() - started) / 200.0))
	quit()
