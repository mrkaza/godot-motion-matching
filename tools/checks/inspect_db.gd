# godot --headless --path . --script res://tools/checks/inspect_db.gd -- <db name> [pose ...]
# Prints a built database's weights and the raw features of a few poses.
extends SceneTree

func _initialize() -> void:
	var args := OS.get_cmdline_user_args()
	var db: PoseDatabase = load("res://databases/%s.res" % args[0]) if args[0].contains("/") else load(_find(args[0]))
	print("db ", db.db_name, " schema ", db.schema_name, " poses ", db.pose_count(), " entries ", db.entry_clip.size(), " dims ", db.dims)
	print("weights ", db.weights)
	for leaf in db.leaves:
		print("  leaf %-32s off=%2d card=%d w=%.3f" % [leaf["label"], leaf["offset"], leaf["cardinality"], leaf["Weight"]])
	var poses := [0, 10, 40] if args.size() < 2 else Array(args.slice(1)).map(func(x): return int(x))
	for p in poses:
		var raw := []
		for d in db.dims:
			raw.append(snappedf(db.raw_value(p, d), 0.01))
		print("pose %d %s t=%.3f addend=%.4f blocked=%d\n  %s" % [p, db.entry_clip[db.pose_entry[p]].get_file(), db.pose_time[p], db.pose_addend[p], db.pose_blocked[p], raw])
	quit()


static func _find(name: String) -> String:
	for dir in ["res://databases"]:
		var stack := [dir]
		while stack:
			var d: String = stack.pop_back()
			for f in DirAccess.get_files_at(d):
				if f == name + ".res":
					return d + "/" + f
			for sub in DirAccess.get_directories_at(d):
				stack.append(d + "/" + sub)
	return ""
