# Player: the sample's character with a third-person camera, keyboard + mouse.
#   Keyboard: WASD move, Shift sprint (hold), Ctrl walk (toggle), C crouch (toggle), Space traverse/jump,
#             Tab strafe/face movement (toggle), mouse camera, mouse wheel zoom, F11 fullscreen,
#             Esc frees the mouse.
class_name Player
extends Node3D

# CameraRig_Medium_Freecam: offset (-220, 40, 30) cm behind/right/up, FOV 80 (horizontal, as in Unreal).
const CAMERA_BACK := 5.5            # default distance: further than the rig's 2.2 m, more of the ground shows
const CAMERA_MIN_BACK := 2.0          # mouse wheel zoom range
const CAMERA_MAX_BACK := 14.0
const CAMERA_ZOOM_STEP := 1.15        # distance factor per wheel notch
const CAMERA_ZOOM_HALFLIFE := 0.08
const CAMERA_RIGHT := 0.4
const CAMERA_UP_PER_BACK := 0.16      # the raised offset grows with the distance (0.6 m at 3.8 m)
const CAMERA_PIVOT_HEIGHT := 0.95     # capsule centre, as the sample's camera rig pivots
const CAMERA_RADIUS := 0.15            # the camera keeps this far from walls
const CAMERA_HALFLIFE_XZ := 0.05       # pivot smoothing (s)
const CAMERA_HALFLIFE_Y := 0.15
const MOUSE_SENSITIVITY := 0.0025

var character: GaspCharacter
var visual: Node3D
var matcher: MotionMatcher
var camera: Camera3D
var camera_yaw := PI         # starts behind the character (it faces +Z)
var camera_pitch := -0.5      # looking down on the character from above
## Camera distance (m) and where the mouse wheel is taking it.
var camera_back := CAMERA_BACK
var camera_back_target := CAMERA_BACK
## Set to drive the character without input (tests, recorded takes): Vector2 in camera space.
var scripted_input = null
## An NPC: no camera, no keyboard/mouse; driven by scripted_input only. Set before adding.
var is_npc := false
## When false the matcher doesn't update (a component such as the ragdoll drives the pose).
var matcher_enabled := true
## Components (traversal, ragdoll...) added with add_component(). Each may implement:
##   on_jump_pressed() -> bool     true when it handled the jump button (traversal before jumping)
##   override_movement(dt) -> bool true when it moved the body itself this frame (skips the
##                                 character's movement tick)
##   after_animation(dt)           called after the pose is updated
##   on_key(event) -> bool         true when it handled a key press
var components: Array[Node] = []


## Adds a component that hooks into this player's frame (see `components`).
func add_component(component: Node) -> void:
	components.append(component)
	add_child(component)


func _ready() -> void:
	_ensure_input()
	character = GaspCharacter.new()
	character.name = "Character"
	add_child(character)
	visual = Node3D.new()
	visual.name = "Visual"
	add_child(visual)
	visual.add_child(Mannequin.instantiate(not is_npc))
	matcher = MotionMatcher.new()
	matcher.name = "MotionMatcher"
	matcher.character = character
	matcher.visual = visual
	add_child(matcher)
	if is_npc:
		return
	camera = Camera3D.new()
	camera.keep_aspect = Camera3D.KEEP_WIDTH
	camera.fov = 80.0
	camera.top_level = true
	# Moved every drawn frame in _process, so it is not interpolated between physics ticks.
	camera.physics_interpolation_mode = Node.PHYSICS_INTERPOLATION_MODE_OFF
	add_child(camera)
	camera.current = true
	Input.mouse_mode = Input.MOUSE_MODE_CAPTURED


func _unhandled_input(event: InputEvent) -> void:
	if is_npc:
		return
	if event is InputEventMouseMotion and Input.mouse_mode == Input.MOUSE_MODE_CAPTURED:
		camera_yaw -= event.relative.x * MOUSE_SENSITIVITY
		camera_pitch = clampf(camera_pitch - event.relative.y * MOUSE_SENSITIVITY, -1.2, 0.8)
	elif event is InputEventMouseButton and event.pressed and event.button_index in [MOUSE_BUTTON_WHEEL_UP, MOUSE_BUTTON_WHEEL_DOWN]:
		var f := 1.0 / CAMERA_ZOOM_STEP if event.button_index == MOUSE_BUTTON_WHEEL_UP else CAMERA_ZOOM_STEP
		camera_back_target = clampf(camera_back_target * f, CAMERA_MIN_BACK, CAMERA_MAX_BACK)
	elif event.is_action_pressed("ui_cancel"):
		Input.mouse_mode = Input.MOUSE_MODE_VISIBLE
	elif event is InputEventMouseButton and event.pressed and Input.mouse_mode != Input.MOUSE_MODE_CAPTURED:
		Input.mouse_mode = Input.MOUSE_MODE_CAPTURED
	elif event.is_action_pressed("fullscreen"):
		var full := DisplayServer.window_get_mode() == DisplayServer.WINDOW_MODE_FULLSCREEN
		DisplayServer.window_set_mode(DisplayServer.WINDOW_MODE_WINDOWED if full else DisplayServer.WINDOW_MODE_FULLSCREEN)
	elif event.is_action_pressed("walk"):
		character.wants_to_walk = not character.wants_to_walk
	elif event.is_action_pressed("crouch"):
		character.wants_to_crouch = not character.wants_to_crouch
	elif event.is_action_pressed("strafe"):
		character.wants_to_strafe = not character.wants_to_strafe
	elif event.is_action_pressed("jump"):
		press_jump()
	elif event is InputEventKey and event.pressed and not event.is_echo():
		for c in components:
			if c.has_method("on_key") and c.on_key(event):
				break


## The jump button: components first (traversal), then a plain jump.
func press_jump() -> void:
	for c in components:
		if c.has_method("on_jump_pressed") and c.on_jump_pressed():
			return
	character.jump()


func _physics_process(dt: float) -> void:
	var input := Vector2.ZERO
	if scripted_input != null:
		input = scripted_input
	elif not is_npc:
		input = Input.get_vector("move_left", "move_right", "move_back", "move_forward")
		character.wants_to_sprint = Input.is_action_pressed("sprint")
	# Camera space to world: forward is the camera's facing on the ground.
	var fwd := Vector2(sin(camera_yaw + PI), cos(camera_yaw + PI))
	var right := Vector2(-fwd.y, fwd.x)
	var world := fwd * input.y + right * input.x
	character.move_input = world.limit_length(1.0)
	character.control_yaw = camera_yaw + PI
	var moved := false
	for c in components:
		if c.has_method("override_movement") and c.override_movement(dt):
			moved = true
	if not moved:
		character.tick(dt)
	if matcher_enabled:
		matcher.update(dt)
	for c in components:
		if c.has_method("after_animation"):
			c.after_animation(dt)


var _pivot := Vector3.INF


## Moves the character to a point (capsule centre) facing `to_yaw`, as Unreal's TeleportTo: velocity
## and the camera's direction are kept; the camera jumps with it instead of trailing across the map.
func teleport(to: Vector3, to_yaw: float) -> void:
	character.global_position = to - Vector3(0, GaspCharacter.CAPSULE_HALF_HEIGHT * GaspCharacter.CM, 0)
	character.yaw = to_yaw
	matcher.visual_yaw = to_yaw
	reset_physics_interpolation()
	_pivot = Vector3.INF


# The camera runs every rendered frame (not only physics ticks), so it stays smooth on fast screens.
func _process(dt: float) -> void:
	if is_npc:
		return
	_update_camera(dt)


func _update_camera(dt: float) -> void:
	# Where the body is drawn this frame: physics moves it 60 times a second, the screen draws faster.
	var target := character.get_global_transform_interpolated().origin + Vector3.UP * CAMERA_PIVOT_HEIGHT
	# While ragdolled (a fall, or the attacker's dive in a tackle) follow the body across the ground,
	# since the capsule trails it, at the same height and distance so the view doesn't change.
	for c in components:
		if c.has_method("is_ragdoll") and c.is_ragdoll():
			var sk := Mannequin.find_skeleton(visual)
			var pelvis := (sk.global_transform * sk.get_bone_global_pose(sk.find_bone("pelvis"))).origin
			target = Vector3(pelvis.x, target.y, pelvis.z)
	camera_back = lerpf(camera_back, camera_back_target, 1.0 - pow(0.5, dt / CAMERA_ZOOM_HALFLIFE))
	var back := camera_back
	var up := back * CAMERA_UP_PER_BACK
	if _pivot == Vector3.INF:
		_pivot = target
	var axz := 1.0 - pow(0.5, dt / CAMERA_HALFLIFE_XZ)
	var ay := 1.0 - pow(0.5, dt / CAMERA_HALFLIFE_Y)
	_pivot = Vector3(lerpf(_pivot.x, target.x, axz), lerpf(_pivot.y, target.y, ay), lerpf(_pivot.z, target.z, axz))
	var rot := Basis(Vector3.UP, camera_yaw) * Basis(Vector3.RIGHT, camera_pitch)
	var want := _pivot + rot * Vector3(CAMERA_RIGHT, up, back)
	# Keep the camera out of walls: sweep a small sphere from the pivot toward where it wants to be.
	var q := PhysicsShapeQueryParameters3D.new()
	var ball := SphereShape3D.new()
	ball.radius = CAMERA_RADIUS
	q.shape = ball
	q.transform = Transform3D(Basis.IDENTITY, _pivot)
	q.motion = want - _pivot
	q.collision_mask = 1
	q.exclude = [character.get_rid()]
	var hit := get_world_3d().direct_space_state.cast_motion(q)
	camera.global_position = _pivot + (want - _pivot) * minf(hit[0], 1.0)
	# Aimed down at the pivot from the raised offset, so the body stays centred in frame.
	camera.global_basis = rot * Basis(Vector3.RIGHT, -atan2(up, back))


static func _ensure_input() -> void:
	var keys := {
		"move_forward": KEY_W, "move_back": KEY_S, "move_left": KEY_A, "move_right": KEY_D,
		"sprint": KEY_SHIFT, "walk": KEY_CTRL, "crouch": KEY_C, "jump": KEY_SPACE, "strafe": KEY_TAB,
		"fullscreen": KEY_F11,
	}
	for action: String in keys:
		if InputMap.has_action(action):
			continue
		InputMap.add_action(action, 0.2)
		var ev := InputEventKey.new()
		ev.physical_keycode = keys[action]
		InputMap.action_add_event(action, ev)
