# The sample's ragdoll (SandboxCharacter_Mover_Ragdoll, BP_MovementMode_Ragdoll, the ABP "Ragdoll"
# state machine and PCA_SandboxCharacter's "Ragdoll" profile)
# as a Player component: player.add_component(preload("res://scripts/ragdoll/ragdoll_component.gd").new())
#
# Default profile (not ragdolled): Kinematic, as the sample's default level's character (no physics
# bodies). "PhysicalAnimation" (RagdollLevel's character): the
# bodies simulate without gravity, world-space and parent-space controls pull them to the animated pose
# every tick (after the matcher), and the mesh shows the bodies, so hits push the body physically.
# Enter (TriggerRagdoll): any action montage stops, profile "Ragdoll" (bodies keep their velocities),
# motion matching pauses, the capsule's rotation is frozen for 0.25 s.
# While ragdolled (Ragdoll_UpdateBehaviors + mover mode "Ragdoll"): COM and spine velocities, impact
# prediction (TimeToImpact, ImpactDirection), roll force from the move input and the floor slope,
# gravity off past 25 m/s down, target pose + parent-space muscles, capsule on the pelvis (ground +
# 87.9 cm) facing the feet when face up and the head when face down (or the COM velocity when rolling).
# Exit (ExitRagdoll -> On_RagdollMode_Exit): jump (or R) with a floor under the capsule, or the NPC rule
# (spine speed <= 10 cm/s, checked again 3 s later); snapshot of the physics pose, CHT_GetUpMontages
# (rolling get-up when the COM moves faster than 150 cm/s) with the PSS_Ragdoll pose search, the
# montage played as a matcher action from the search's start time, blended in from the snapshot with
# the montage's blend-in; root motion moves the capsule; movement input in the montage's
# BP_NotifyState_MontageBlendOut window ends it early; then motion matching takes over.
#
# Hooks used: override_movement, after_animation, on_key (R), on_jump_pressed.
extends Node

const BODY := preload("res://scripts/ragdoll/ragdoll_body.gd")
const POSES := preload("res://scripts/ragdoll/ragdoll_poses.gd")
const GETUP := preload("res://scripts/ragdoll/getup_chooser.gd")
const SNAPSHOT := preload("res://scripts/ragdoll/snapshot_blend.gd")
const CM := 0.01

const FREEZE_CAPSULE_ROTATION_TIME := 0.25   # RetriggerableDelay in TriggerRagdoll
const ROLLING_GETUP_SPEED := 150.0           # cm/s, Ragdoll_PlayRollingGetups
const CAPSULE_TRACE_LENGTH := 0.88           # BP_MovementMode_Ragdoll sphere trace
const CAPSULE_TRACE_RADIUS := 0.30
const CAPSULE_HALF_HEIGHT := 0.86
const CAPSULE_LIFT := 0.019                  # + 1.9 cm
const PREDICT_RADIUS := 0.20                 # PredictProjectilePath: radius 20, 1 s at 10 Hz
const PREDICT_TIME := 1.0
const PREDICT_STEPS := 10
const ROLL_TORQUE := 100000.0                # deg/s^2 (AddTorqueInDegrees, accel change)
const TERMINAL_FALL_SPEED := 2500.0          # cm/s, gravity off below
const SETTLE_SPEED := 10.0                   # cm/s, NPC_GetupCheck
const SETTLE_DELAY := 3.0
const OBSTACLE_RADIUS := 0.15                # TraceForObstacles
const BLEND_OUT_INPUT := 0.1
const IMPULSE_RADIUS := 0.25                 # m, spread of start_ragdoll's impulse around the point

enum Mode { OFF, RAGDOLL, GETUP }

## The physics profile while not ragdolled. "Kinematic" (bodies off until a ragdoll, hit, shove or
## tackle) is the sample's main character: DefaultLevel spawns GM_Sandbox's SandboxCharacter_Mover,
## which has no PhysicsControlComponent, so its hands and feet are the animation. "PhysicalAnimation"
## is RagdollLevel's SandboxCharacter_Mover_Ragdoll (DDCVar.CharacterPhysics.DefaultProfile = 1):
## every body simulated without gravity, pulled to the animation (world-space 3 Hz, feet 10 Hz,
## parent-space 15 Hz), the mesh showing the bodies, which also collide with ledges.
@export_enum("PhysicalAnimation", "Kinematic") var default_profile := "Kinematic"
## NPC rule: stand up by itself once the spine has been still (<= 10 cm/s) and still is 3 s later.
@export var auto_getup := true
## Collision mask of "Obstacle" objects that knock the character over (TraceForObstacles); 0 = off.
@export_flags_3d_physics var obstacle_mask := 0

signal ragdoll_started
signal getup_started(montage: String)
signal getup_finished

var player: Player
var character: GaspCharacter
var matcher: MotionMatcher
var skeleton: Skeleton3D
var body
var poses
var getup
var snapshot: SkeletonModifier3D
var mode := Mode.OFF
var injury := 0
var time_in_mode := 0.0

# Ragdoll_UpdateVelocities / ImpactDirection / RollBehavior (cm, cm/s, degrees).
var com_velocity := Vector3.ZERO
var speed := 0.0
var time_to_impact := 1.0
var impact_direction := Vector2.ZERO
var roll_force := Vector3.ZERO
var face_up := false
var has_floor := false
## The pick of the last exit: chooser row + "time", "cost", "face_up", "rolling".
var last_getup := {}
## Seconds in the last ragdoll until it was still for good (the NPC check's start), -1 while moving.
var settle_time := -1.0

var _i_pelvis := -1
var _i_spine := -1
var _i_trace_bone := -1
var _trace_socket := Transform3D.IDENTITY   # RagdollTrace in spine_03's frame
var _com_last := Vector3.ZERO
var _auto_roll := Vector3.ZERO
var _floor_normal := Vector3.UP
var _still_check_at := -1.0
var _history: Array = []      # [time, capsule position] while ragdolled
var _last_world: Array = []   # body frames from the animation, last two frames
var _prev_world: Array = []
var _blend_in := 0.0
var _blend_option := ""
var _blend_window := Vector2(-1, -1)
var _exit_frame := false      # the tick of ExitRagdoll: no controls (strengths 0), profile next tick


func _ready() -> void:
	player = get_parent()
	if OS.has_environment("RAGDOLL_DEFAULT_PROFILE"):  # for A/B checks (test_foot_sliding.gd)
		default_profile = OS.get_environment("RAGDOLL_DEFAULT_PROFILE")
	character = player.character
	matcher = player.matcher
	skeleton = Mannequin.find_skeleton(player.visual)
	body = BODY.new(skeleton, character)
	snapshot = SNAPSHOT.new()
	snapshot.name = "RagdollSnapshot"
	snapshot.active = false
	skeleton.add_child(snapshot)
	# Modifier order: the clip skeleton's offsets under the animation (what the bodies simulate), the
	# snapshot over it, then the bodies over the bones, then the retarget onto Manny and the foot lock
	# (and anything else) on the pose as drawn.
	skeleton.move_child(body.geometry, 0)
	skeleton.move_child(snapshot, 1)
	skeleton.move_child(body.simulator, 2)
	skeleton.move_child(body.pose_writer, 3)
	# The blend stack's per-bone blend and orientation warping are part of the animated pose: over the
	# clip offsets, under the snapshot.
	skeleton.move_child(matcher.blend_stack_pose, 1)
	skeleton.move_child(matcher.slide_slope, 2)  # the slide lean too
	poses = POSES.new(body.names, skeleton)
	getup = GETUP.new(skeleton)
	_i_pelvis = body.names.find("pelvis")
	_i_spine = body.names.find("spine_05")
	_i_trace_bone = body.names.find("spine_03")
	_trace_socket = Transform3D(Basis(BODY.rotator_to_glb([0.0, 90.0, -90.0])), BODY.to_glb([20.0, 0.0, 0.0]) * CM)
	matcher.load_clips(getup.rows.map(func(r): return r["clip"]))


func _exit_tree() -> void:
	if body != null:
		body.release()


func is_ragdoll() -> bool:
	return mode == Mode.RAGDOLL


## True while the bodies simulate (PhysicalAnimation or ragdoll): things can hit them.
func bodies_active() -> bool:
	return body.simulating


# ------------------------------------------------------------------ player hooks

func override_movement(dt: float) -> bool:
	match mode:
		Mode.RAGDOLL:
			_ragdoll_tick(dt)
			return true
		Mode.GETUP:
			if matcher.action_clip == "":
				_end_getup()
				return false
			time_in_mode += dt
			var t: Vector3 = matcher.action_root_translation
			character.velocity = Vector3(t.x, 0.0, t.z) / dt
			character.move_and_slide()
			character.velocity_cm = Vector3(character.velocity.x, 0.0, character.velocity.z) / CM
			character.yaw = matcher.visual_yaw
			return true
	if obstacle_mask != 0 and _obstacle_hit():
		trigger_ragdoll()
		_ragdoll_tick(dt)
		return true
	return false


func after_animation(dt: float) -> void:
	if mode == Mode.RAGDOLL:
		return
	if mode == Mode.GETUP:
		var a := _blend_alpha(time_in_mode / maxf(_blend_in, 1e-3))
		snapshot.influence = 1.0 - a
		if a >= 1.0:
			snapshot.active = false
		var ct: float = matcher.blend.get_current_time()
		if matcher.action_clip != "" and ct >= _blend_window.x and ct <= _blend_window.y 				and character.move_input.length() > BLEND_OUT_INPUT:
			matcher.stop_action()
	_record_animated_pose()
	if _exit_frame and body.profile == "Ragdoll":
		body.drive([], _animated_targets()[1], Vector4.ZERO, dt)  # parent-space strengths 0
	elif body.profile != default_profile:
		var was_simulating: bool = body.simulating
		var velocities := _start_velocities()
		body.set_profile(default_profile, velocities)
		# First start, no animated history yet: the simulator starts the bodies on the last pose it saw,
		# from before the first animated frame; put them on this one.
		if not was_simulating and velocities.is_empty() and body.simulating:
			body.teleport(_animated_targets()[0])
	_exit_frame = false
	if body.profile == "PhysicalAnimation":
		var t := _animated_targets()
		body.drive(t[0], t[1], Vector4.ONE, dt)


## The animated pose of the body bones on the clip skeleton (with the get-up's snapshot blended in):
## world transforms and local rotations, as the controls' targets.
func _animated_targets() -> Array:
	var xf := skeleton.global_transform
	var world := []
	var local := []
	if snapshot.active and snapshot.poses.size() == skeleton.get_bone_count():
		var locals := []
		var w: float = snapshot.influence
		for b in skeleton.get_bone_count():
			locals.append(body.local_pose(b).interpolate_with(snapshot.poses[b], w))
		var globals: Array[Transform3D] = body.globals_of(locals)
		for i in body.bodies.size():
			var b: int = body.bone_ids[i]
			world.append(xf * globals[b])
			local.append(skeleton.get_bone_pose_rotation(b).slerp((snapshot.poses[b] as Transform3D).basis.get_rotation_quaternion(), w))
		return [world, local]
	var globals: Array[Transform3D] = body.animated_globals()
	for i in body.bodies.size():
		var b: int = body.bone_ids[i]
		world.append(xf * globals[b])
		local.append(skeleton.get_bone_pose_rotation(b))
	return [world, local]


func on_key(event: InputEvent) -> bool:
	var key := event as InputEventKey
	if key == null or (key.physical_keycode != KEY_R and key.keycode != KEY_R):
		return false
	if mode == Mode.RAGDOLL:
		if has_floor:
			exit_ragdoll()
	else:
		trigger_ragdoll()
	return true


func on_jump_pressed() -> bool:
	if mode == Mode.RAGDOLL:
		if has_floor:
			exit_ragdoll()
		return true
	return mode == Mode.GETUP


# ------------------------------------------------------------------ enter

## A hit or shove: ragdoll now (if not already) and an impulse (kg m/s) at a world point
## (Vector3.INF = the chest). The impulse is shared by the bodies around the point (by mass, falling
## off over IMPULSE_RADIUS): a whole shove on one light body (head 2.5 kg, neck 0.55 kg) is more than
## Jolt's joints can pass on in one step and tears the chain apart.
func start_ragdoll(impulse: Vector3, at_point := Vector3.INF) -> void:
	trigger_ragdoll()
	push(impulse, at_point)


## start_ragdoll's impulse without the ragdoll: a hit on the simulated bodies (PhysicalAnimation).
func push(impulse: Vector3, at_point := Vector3.INF) -> void:
	if impulse == Vector3.ZERO or not body.simulating:
		return
	var p := at_point
	if not p.is_finite():
		p = body.body_transform(body.names.find("spine_03")).origin
	var weights := []
	var total := 0.0
	for i in body.bodies.size():
		var d: float = body.body_transform(i).origin.distance_to(p)
		var w: float = body.mass[i] * exp(-d * d / (2.0 * IMPULSE_RADIUS * IMPULSE_RADIUS))
		weights.append(w)
		total += w
	for i in body.bodies.size():
		if weights[i] > 1e-6 * total:
			PhysicsServer3D.body_apply_central_impulse(body.bodies[i].get_rid(), impulse * weights[i] / total)


## TriggerRagdoll(StopActiveMontages, MontageBlendOut, Ragdoll_InjuryState); injury uses
## ragdoll_poses.gd Injury (0 None .. 6 Groin).
func trigger_ragdoll(stop_active_montages := true, injury_state := 0) -> void:
	if mode == Mode.RAGDOLL:
		return  # QueueNextMode("Ragdoll", bShouldReenter = false)
	if stop_active_montages and matcher.action_clip != "":
		matcher.stop_action()
	snapshot.active = false
	injury = injury_state
	var pre := []
	for i in body.bodies.size():
		pre.append(skeleton.get_bone_pose_rotation(body.bone_ids[i]))
	body.set_profile("Ragdoll", [] if body.simulating else _start_velocities())
	player.matcher_enabled = false
	mode = Mode.RAGDOLL
	time_in_mode = 0.0
	settle_time = -1.0
	_still_check_at = -1.0
	_auto_roll = Vector3.ZERO
	_history.clear()
	_com_last = body.center_of_mass()
	_predict_impact()
	poses.reset(pre, time_to_impact, injury)
	ragdoll_started.emit()


func _start_velocities() -> Array:
	var out := []
	if _last_world.size() != body.bodies.size() or _prev_world.size() != body.bodies.size():
		return out
	var dt := get_physics_process_delta_time()
	for i in body.bodies.size():
		var a: Transform3D = _prev_world[i]
		var b: Transform3D = _last_world[i]
		var turn := b.basis.get_rotation_quaternion() * a.basis.get_rotation_quaternion().inverse()
		out.append([(b.origin - a.origin) / dt, BODY._axis_angle(turn) / dt])
	return out


func _record_animated_pose() -> void:
	_prev_world = _last_world
	_last_world = []
	var xf := skeleton.global_transform
	var globals: Array[Transform3D] = body.animated_globals()
	for i in body.bodies.size():
		_last_world.append(xf * globals[body.bone_ids[i]] * body.bodies[i].body_offset)


func _obstacle_hit() -> bool:
	var neck := skeleton.global_transform * skeleton.get_bone_global_pose(skeleton.find_bone("neck_01"))
	var fl := skeleton.global_transform * skeleton.get_bone_global_pose(skeleton.find_bone("foot_l"))
	var fr := skeleton.global_transform * skeleton.get_bone_global_pose(skeleton.find_bone("foot_r"))
	var params := PhysicsShapeQueryParameters3D.new()
	var sphere := SphereShape3D.new()
	sphere.radius = OBSTACLE_RADIUS
	params.shape = sphere
	params.transform = Transform3D(Basis.IDENTITY, neck.origin)
	params.motion = (fl.origin + fr.origin) * 0.5 - neck.origin
	params.collision_mask = obstacle_mask
	params.exclude = [character.get_rid()]
	var r := character.get_world_3d().direct_space_state.cast_motion(params)
	return r.size() == 2 and r[1] < 1.0


# ------------------------------------------------------------------ while ragdolled

func _ragdoll_tick(dt: float) -> void:
	time_in_mode += dt
	# The matcher is paused: the feet layer passes the pose through (MovementMode Ragdoll).
	var foot_lock = matcher.get("foot_lock")
	if foot_lock != null:
		foot_lock.movement_mode = "Ragdoll"
	# Ragdoll_UpdateVelocities.
	var com: Vector3 = body.center_of_mass()
	com_velocity = (com - _com_last) / dt / CM
	_com_last = com
	speed = body.state(_i_spine).linear_velocity.length() / CM
	_predict_impact()
	_update_roll(dt)
	# Ragdoll_UpdateGravity.
	body.set_gravity_scale(0.0 if com_velocity.y <= -TERMINAL_FALL_SPEED else 1.0)
	# Target pose and muscles (ABP, then PostABPTick: Ragdoll_UpdatePhysicsStrengthsFromCurves).
	var targets: Array = poses.update(dt, time_to_impact, impact_direction, roll_force.length())
	var spin := {}
	if roll_force.length_squared() > 1e-8:
		spin[_i_spine] = Vector3.UP.cross(roll_force) * deg_to_rad(ROLL_TORQUE) * dt
	body.drive([], targets, poses.curves, dt, spin)
	_follow_pelvis(dt)
	# NPC_GetupCheck: DoOnce on a still spine, Delay 3 s, still again -> ExitRagdoll.
	if _still_check_at < 0.0 and absf(speed) <= SETTLE_SPEED:
		_still_check_at = time_in_mode + SETTLE_DELAY
		settle_time = time_in_mode
	elif _still_check_at >= 0.0 and time_in_mode >= _still_check_at:
		_still_check_at = -1.0
		if absf(speed) <= SETTLE_SPEED and auto_getup:
			exit_ragdoll()
		else:
			settle_time = -1.0


## Ragdoll_UpdateImpactDirection: a 20 cm sphere thrown from the RagdollTrace socket with spine_05's
## velocity under gravity for 1 s at 10 Hz; time and direction (yaw, pitch in the socket's frame) to
## where it hits. The socket (read from SK_UEFN_Mannequin.uasset): bone spine_03, 20 cm along its X
## (up the spine), rotation (pitch 0, yaw 90, roll -90): X forward out of the chest, Z up the spine.
func _predict_impact() -> void:
	var s: PhysicsDirectBodyState3D = body.state(_i_spine)
	var socket: Transform3D = body.bone_world(_i_trace_bone) * _trace_socket
	var o := socket.origin
	var v := s.linear_velocity
	var g := Vector3.DOWN * float(ProjectSettings.get_setting("physics/3d/default_gravity", 9.8))
	var params := PhysicsShapeQueryParameters3D.new()
	var sphere := SphereShape3D.new()
	sphere.radius = PREDICT_RADIUS
	params.shape = sphere
	params.collision_mask = 1
	params.exclude = [character.get_rid()]
	var space := character.get_world_3d().direct_space_state
	var step := PREDICT_TIME / PREDICT_STEPS
	var p := o
	var hit_time := PREDICT_TIME
	var hit_at := Vector3.INF
	params.transform = Transform3D(Basis.IDENTITY, o)
	if not space.intersect_shape(params, 1).is_empty():
		hit_time = 0.0  # the sphere starts touching (cast_motion ignores a start overlap)
		hit_at = o
	for k in (0 if hit_time == 0.0 else PREDICT_STEPS):
		var next := p + v * step + 0.5 * g * step * step
		params.transform = Transform3D(Basis.IDENTITY, p)
		params.motion = next - p
		var r := space.cast_motion(params)
		if r.size() == 2 and r[1] < 1.0:
			hit_time = (k + r[1]) * step
			hit_at = p + (next - p) * r[1]
			break
		v += g * step
		p = next
	if not hit_at.is_finite():
		hit_at = p
	time_to_impact = hit_time
	var d := hit_at - o
	if d.length() < 0.01:
		# Already touching (UE's GetSafeNormal would give zero): the way the path starts.
		d = s.linear_velocity * step + 0.5 * g * step * step
	# InverseTransformDirection(socket), back to Unreal's axes (Y negated) for the yaw/pitch.
	var l := socket.basis.orthonormalized().inverse() * d
	l.y = -l.y
	impact_direction = Vector2(rad_to_deg(atan2(l.y, l.x)), rad_to_deg(atan2(l.z, Vector2(l.x, l.y).length())))


## Ragdoll_UpdateRollBehavior: roll force = move input + downhill push on floors steeper than 20 deg.
func _update_roll(dt: float) -> void:
	var floor_angle := rad_to_deg(acos(clampf(_floor_normal.dot(Vector3.UP), -1.0, 1.0)))
	var target := _floor_normal * clampf((floor_angle - 20.0) / 10.0, 0.0, 1.0)
	var rate := 0.5 if target.length() < _auto_roll.length() else 2.0
	_auto_roll = _auto_roll.move_toward(target, rate * dt)
	var input := Vector3(character.move_input.x, 0.0, character.move_input.y)
	roll_force = (input + _auto_roll).limit_length(1.0)


## BP_MovementMode_Ragdoll + Get_RagdollTransform + Get_RagdollTargetOrientation.
func _follow_pelvis(dt: float) -> void:
	var pelvis: Vector3 = body.bone_world(_i_pelvis).origin
	var chest: Transform3D = body.bone_world(_i_spine)
	var v := chest.origin - pelvis
	face_up = (-chest.basis.y).y > 0.0
	var x := -v if face_up else v
	var space := character.get_world_3d().direct_space_state
	var params := PhysicsShapeQueryParameters3D.new()
	var sphere := SphereShape3D.new()
	sphere.radius = CAPSULE_TRACE_RADIUS
	params.shape = sphere
	params.transform = Transform3D(Basis.IDENTITY, pelvis)
	params.motion = Vector3.DOWN * CAPSULE_TRACE_LENGTH
	params.collision_mask = 1
	params.exclude = [character.get_rid()]
	# The pelvis sphere usually starts inside the floor when lying (cast_motion then reports no hit),
	# so the floor height comes from a ray under the pelvis; the sphere covers ledges the ray misses.
	var ray := PhysicsRayQueryParameters3D.create(pelvis, pelvis + Vector3.DOWN * (CAPSULE_TRACE_LENGTH + CAPSULE_TRACE_RADIUS), 1, [character.get_rid()])
	var hit := space.intersect_ray(ray)
	var ground := -INF
	if hit:
		ground = (hit["position"] as Vector3).y
		_floor_normal = hit["normal"]
	elif not space.intersect_shape(params, 1).is_empty():
		ground = pelvis.y - CAPSULE_TRACE_RADIUS
		_floor_normal = Vector3.UP
	else:
		var r := space.cast_motion(params)
		if r.size() == 2 and r[1] < 1.0:
			ground = pelvis.y - CAPSULE_TRACE_LENGTH * r[1] - CAPSULE_TRACE_RADIUS
		_floor_normal = Vector3.UP
	has_floor = ground > -INF
	var origin_y := ground + CAPSULE_LIFT if has_floor else pelvis.y - CAPSULE_HALF_HEIGHT
	var pos := Vector3(pelvis.x, origin_y, pelvis.z)
	character.velocity_cm = (pos - character.global_position) / dt / CM
	character.global_position = pos
	character.movement_mode = GaspCharacter.MovementMode.ON_GROUND if has_floor else GaspCharacter.MovementMode.IN_AIR
	_history.append([time_in_mode, pos])
	while _history.size() > 2 and _history[1][0] < time_in_mode - 0.6:
		_history.pop_front()
	if time_in_mode < FREEZE_CAPSULE_ROTATION_TIME:
		return
	var com_xy := Vector2(com_velocity.x, com_velocity.z)
	if com_xy.length() > ROLLING_GETUP_SPEED:
		character.yaw = atan2(com_xy.x, com_xy.y)
	elif Vector2(x.x, x.z).length() > 1e-4:
		character.yaw = atan2(x.x, x.z)


# ------------------------------------------------------------------ exit

## ExitRagdoll -> On_RagdollMode_Exit.
func exit_ragdoll() -> void:
	if mode != Mode.RAGDOLL:
		return
	var world := {}
	var named := {}
	for i in body.bodies.size():
		var xf: Transform3D = body.bone_world(i)
		world[body.bone_ids[i]] = xf
		named[body.names[i]] = xf
	var rolling := Vector2(com_velocity.x, com_velocity.z).length() > ROLLING_GETUP_SPEED
	var yaw := character.yaw
	var root_world := Transform3D(Basis(Vector3.UP, yaw) * Mannequin.SKELETON_TURN, character.global_position)
	var q: PackedFloat32Array = getup.query(named, root_world, _past_position(0.5))
	var pick: Dictionary = getup.choose("OnGround", rolling, q)
	# On_RagdollMode_Exit: this tick the parent-space strengths go to 0; next tick the default profile
	# (after_animation). The bodies are where the snapshot is, so PhysicalAnimation takes over from it.
	_exit_frame = true
	if default_profile == "Kinematic":
		body.set_profile("Kinematic")
	# The capsule already stands under the pelvis with the get-ups' yaw: put the mesh there.
	player.visual.global_position = character.global_position
	player.visual.global_basis = Basis(Vector3.UP, yaw)
	# A jump, not motion: without this the frames drawn this tick slide the mesh from where it was
	# during the ragdoll while the snapshot pose is already placed for here (a one-tick flicker).
	player.visual.reset_physics_interpolation()
	matcher.visual_yaw = yaw
	_take_snapshot(world)
	player.matcher_enabled = true
	character.velocity_cm = Vector3.ZERO
	character.velocity = Vector3.ZERO
	character.movement_mode = GaspCharacter.MovementMode.ON_GROUND
	pick["face_up"] = face_up
	pick["rolling"] = rolling
	pick["ragdoll_time"] = time_in_mode
	last_getup = pick
	if not pick.has("clip"):
		snapshot.active = false
		mode = Mode.OFF
		return
	matcher.play_action(pick["clip"], pick["time"], pick["end"], 0.0, 1.0)
	_blend_in = pick["blend_in"]
	_blend_option = pick["blend_in_option"]
	_blend_window = pick["blend_out_window"]
	mode = Mode.GETUP
	time_in_mode = 0.0
	getup_started.emit(pick["montage"])


func _past_position(ago: float) -> Vector3:
	if _history.is_empty():
		return character.global_position
	var t := time_in_mode - ago
	for k in range(_history.size() - 1, -1, -1):
		if _history[k][0] <= t:
			if k + 1 < _history.size():
				var a: Array = _history[k]
				var b: Array = _history[k + 1]
				return (a[1] as Vector3).lerp(b[1], clampf((t - a[0]) / maxf(b[0] - a[0], 1e-6), 0.0, 1.0))
			return _history[k][1]
	return _history[0][1]


## Pose snapshot "Ragdoll": physics bones from their bodies, the rest following their animated local
## pose, as local poses in the skeleton at its new place.
func _take_snapshot(world: Dictionary) -> void:
	var inv := skeleton.global_transform.affine_inverse()
	var n := skeleton.get_bone_count()
	var globals: Array[Transform3D] = []
	globals.resize(n)
	var locals: Array[Transform3D] = []
	locals.resize(n)
	for b in n:
		var p := skeleton.get_bone_parent(b)
		var g: Transform3D
		if world.has(b):
			g = (inv * (world[b] as Transform3D)).orthonormalized()
		else:
			g = (globals[p] if p >= 0 else Transform3D.IDENTITY) * body.local_pose(b)
		globals[b] = g
		locals[b] = g if p < 0 else globals[p].affine_inverse() * g
	snapshot.poses = locals
	snapshot.influence = 1.0
	snapshot.active = true


func _blend_alpha(t: float) -> float:
	t = clampf(t, 0.0, 1.0)
	match _blend_option:
		"QuadraticInOut":
			return 2.0 * t * t if t < 0.5 else 1.0 - pow(-2.0 * t + 2.0, 2.0) * 0.5
		"Custom":
			# Curve_Ragdoll_Getup_Roll_BlendIn: (0, 0) leave tangent 2.359244 -> (1, 1) arrive tangent 0.
			var m0 := 2.359244
			return (t * t * t - 2.0 * t * t + t) * m0 + (-2.0 * t * t * t + 3.0 * t * t)
		"Linear":
			return t
	return t * t * (3.0 - 2.0 * t)


func _end_getup() -> void:
	mode = Mode.OFF
	snapshot.active = false
	getup_finished.emit()
