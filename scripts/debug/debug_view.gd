# Motion matching debug view (F1): the trajectory the search matches against (past in blue,
# prediction in green, facing ticks), the visual root's facing, and a readout of the database,
# clip, cost and speed. Added to the player with Player.add_component().
extends Node3D

const PAST := Color(0.35, 0.65, 1.0)
const FUTURE := Color(0.3, 1.0, 0.45)
const FACING := Color(1.0, 0.85, 0.25)
const ROOT := Color(1.0, 0.35, 0.3)
const LIFT := 0.03
const WIDTH := 0.035  # ribbon width in metres, readable at 1080p

var player
var shown := false  # F1
var _mesh := ImmediateMesh.new()
var _lines := MeshInstance3D.new()
var _label := Label.new()


func _ready() -> void:
	player = get_parent()
	var mat := StandardMaterial3D.new()
	mat.shading_mode = BaseMaterial3D.SHADING_MODE_UNSHADED
	mat.vertex_color_use_as_albedo = true
	mat.no_depth_test = true
	mat.cull_mode = BaseMaterial3D.CULL_DISABLED
	mat.render_priority = 10
	_lines.mesh = _mesh
	_lines.material_override = mat
	_lines.top_level = true
	add_child(_lines)
	var layer := CanvasLayer.new()
	add_child(layer)
	_label.position = Vector2(24, 20)
	_label.add_theme_font_size_override("font_size", 26)
	_label.add_theme_color_override("font_outline_color", Color.BLACK)
	_label.add_theme_constant_override("outline_size", 6)
	layer.add_child(_label)


func on_key(event: InputEventKey) -> bool:
	if event.physical_keycode == KEY_F1:
		shown = not shown
		return true
	return false


func after_animation(_dt: float) -> void:
	_mesh.clear_surfaces()
	_label.visible = shown
	if not shown:
		return
	var m: MotionMatcher = player.matcher
	var traj: TransformTrajectory = m.trajectory
	if traj.sample_count() == 0:
		return
	_mesh.surface_begin(Mesh.PRIMITIVE_TRIANGLES)
	for i in range(1, traj.sample_count()):
		var a := traj.positions[i - 1] + Vector3.UP * LIFT
		var b := traj.positions[i] + Vector3.UP * LIFT
		_line(a, b, PAST if traj.times[i] <= 0.0 else FUTURE)
	for i in range(TransformTrajectory.HISTORY_COUNT, traj.sample_count(), 3):
		var p := traj.positions[i] + Vector3.UP * LIFT
		var f := float(traj.facings[i])
		_line(p, p + Vector3(sin(f), 0, cos(f)) * 0.25, FACING)
	var root: Vector3 = player.character.global_position + Vector3.UP * LIFT
	_line(root, root + Vector3(sin(m.visual_yaw), 0, cos(m.visual_yaw)) * 0.6, ROOT)
	_mesh.surface_end()

	var clip := "-"
	if m.action_clip != "":
		clip = "action: " + m.action_clip.get_file().get_basename()
	elif m.current_pose >= 0 and m.databases.has(m.current_db):
		var db: PoseDatabase = m.databases[m.current_db]
		clip = db.entry_clip[db.pose_entry[m.current_pose]].get_file().get_basename()
	_label.text = "%s\n%s\ncost %.3f   speed %.0f cm/s   %s %s %s" % [
		m.current_db.get_file() if m.current_db != "" else "-", clip, m.current_cost,
		player.character.speed_2d(), m.vars.get("Gait", ""), m.vars.get("Stance", ""), m.vars.get("MovementState", "")]


## A flat ribbon from a to b, lying on the ground plane.
func _line(a: Vector3, b: Vector3, color: Color) -> void:
	var d := b - a
	d.y = 0.0
	if d.length_squared() < 1e-8:
		return
	var side := Vector3(-d.z, 0, d.x).normalized() * WIDTH * 0.5
	for v in [a - side, a + side, b + side, a - side, b + side, b - side]:
		_mesh.surface_set_color(color)
		_mesh.surface_add_vertex(v)
