# Cycles the player's body through Manny and the custom bodies (Mannequin.BODY_MESHES); the NPC is
# always Manny: the button at the bottom right (Esc frees the mouse) or B. Added to the player with
# Player.add_component().
extends Node

var player
var _button := Button.new()


func _ready() -> void:
	player = get_parent()
	var layer := CanvasLayer.new()
	add_child(layer)
	_button.focus_mode = Control.FOCUS_NONE  # Space and Enter stay jump and the rest
	_button.add_theme_font_size_override("font_size", 22)
	_button.set_anchors_and_offsets_preset(Control.PRESET_BOTTOM_RIGHT, Control.PRESET_MODE_MINSIZE, 24)
	_button.grow_horizontal = Control.GROW_DIRECTION_BEGIN
	_button.grow_vertical = Control.GROW_DIRECTION_BEGIN
	_button.pressed.connect(toggle)
	layer.add_child(_button)
	_update_text.call_deferred()


func on_key(event: InputEventKey) -> bool:
	if event.physical_keycode == KEY_B:
		toggle()
		return true
	return false


## Shows the next body (Manny, then each of Mannequin.BODY_MESHES) on the player; the NPC stays Manny.
func toggle() -> void:
	var bodies: Array = [""] + Mannequin.available_bodies()
	set_body(player, bodies[(bodies.find(_shown(player)) + 1) % bodies.size()])
	_update_text()


## Shows the body at `path` ("" for Manny); a body is attached the first time it is shown.
static func set_body(p: Player, path: String) -> void:
	var manny: Node3D = p.visual.get_child(0)
	var ms := Mannequin.find_skeleton(manny)
	var attached := false
	for m in _bodies(ms):
		var on: bool = m.get_meta("body_path") == path
		attached = attached or on
		m.active = on
		m.visible = on
	if path != "" and not attached:
		CustomBody.attach(manny, path)  # hides Manny's meshes
		return
	for c in ms.get_children():
		if c is MeshInstance3D:
			(c as MeshInstance3D).visible = path == ""


static func _bodies(ms: Skeleton3D) -> Array:
	return ms.get_children().filter(func(c: Node) -> bool: return c is SkeletonModifier3D and c.has_meta("body_path"))


static func _shown(p: Player) -> String:
	for m in _bodies(Mannequin.find_skeleton(p.visual.get_child(0))):
		if m.visible:
			return m.get_meta("body_path")
	return ""


func _update_text() -> void:
	var path := _shown(player)
	_button.text = "Body: %s  [B]" % (path.get_file().get_basename().capitalize() if path != "" else "Manny")
