# The sample's SandboxCharacter_CMC on a CharacterBody3D: input state, gait, and Unreal's
# CharacterMovementComponent ground and air rules (CalcVelocity / ApplyVelocityBraking, read from
# CharacterMovementComponent.cpp). Values come from SandboxCharacter_CMC and its class defaults
# Internally in Unreal units (cm, cm/s, degrees) so the
# constants stay exact; the body moves in metres.
# The CMC character has no slide; the slide here is the default level's Mover character's
# (BP_MovementMode_Slide on USmoothWalkingMode, BP_MovementTransition_ToSlide / _FromSlide, values
# from their class defaults, extracted/t3d/Blueprints/MovementModes): crouch above 380 cm/s.
class_name GaspCharacter
extends CharacterBody3D

const CM := 0.01
const GRAVITY := 980.0                 # cm/s^2, GravityScale 1
const JUMP_Z_VELOCITY := 500.0         # class default
const AIR_CONTROL := 0.25              # class default
const MIN_ANALOG_WALK_SPEED := 150.0   # class default
const BRAKING_FRICTION_FACTOR := 0.0   # class default
const BRAKING_SUBSTEP := 1.0 / 33.0
const BRAKE_TO_STOP_VELOCITY := 10.0
const CAPSULE_RADIUS := 30.0
const CAPSULE_HALF_HEIGHT := 86.0
const CROUCHED_HALF_HEIGHT := 60.0
const ANALOG_WALK_RUN_THRESHOLD := 0.7

const WALK_SPEEDS := Vector3(200, 180, 150)    # forward, strafe, back
const RUN_SPEEDS := Vector3(500, 350, 300)
const SPRINT_SPEEDS := Vector3(700, 700, 700)
const CROUCH_SPEEDS := Vector3(225, 200, 180)
# Curve_StrafeSpeedMap: |direction| in degrees -> 0 forward, 1 sideways, 2 back (linear keys).
const STRAFE_MAP_KEYS := [Vector2(0, 0), Vector2(45, 0), Vector2(80, 1), Vector2(100, 1), Vector2(135, 2), Vector2(180, 2)]

enum Gait { WALK, RUN, SPRINT }
enum Stance { STAND, CROUCH }
enum MovementMode { ON_GROUND, IN_AIR, SLIDING }

const SMOOTH_WALKING := preload("res://scripts/character/smooth_walking.gd")
# Slide (Mover): BP_MovementTransition_ToSlide / _FromSlide.
const SLIDE_ENTER_SPEED := 380.0
const SLIDE_EXIT_SPEED := 200.0
# BP_MovementMode_Slide class defaults.
const SLIDE_INITIAL_BOOST_TIME := 0.2
const SLIDE_INITIAL_BOOST_SPEED := 800.0
const SLIDE_INITIAL_BOOST_ACCELERATION := 2000.0
const SLIDE_AFTER_BOOST_ACCELERATION := 300.0
const SLIDE_STEEP_SLOPE_ANGLE := 40.0
const SLIDE_SHALLOW_SLOPE_ANGLE := 10.0
const SLIDE_STEEP_SLOPE_SPEED := 800.0
const SLIDE_SHALLOW_SLOPE_SPEED := 500.0
const SLIDE_FLAT_GROUND_SPEED := 100.0
const SLIDE_STEEP_SLOPE_DECELERATION := 2000.0
const SLIDE_FLAT_GROUND_DECELERATION := 500.0
## Desired speed before the mode has set its MaxSpeedOverride: the Mover pawn's crouched max speed
## (StanceSettings CrouchingMaxSpeed).
const SLIDE_LEGACY_MAX_SPEED := 200.0
const SLIDE_WALK_PARAMS := {
	"directional_acceleration_factor": 1.0, "turning_strength": 1.0,
	"acceleration_smoothing_time": 0.0, "deceleration_smoothing_time": 0.0,
	"acceleration_smoothing_compensation": 0.0, "deceleration_smoothing_compensation": 0.0,
	"outside_influence_smoothing_time": 0.05, "velocity_deadzone": 0.01, "acceleration_deadzone": 0.001,
	"facing_smoothing_time": 0.15, "double_spring": false, "facing_deadzone": 0.1, "angular_velocity_deadzone": 0.01,
}

# Input state (S_PlayerInputState). Strafe is on by default in the sample.
var wants_to_sprint := false
var wants_to_walk := false
var wants_to_strafe := true
var wants_to_aim := false
var wants_to_crouch := false
## Movement input in world space (x, z), length up to 1. Set by the controller each frame.
var move_input := Vector2.ZERO
## Camera yaw (radians), used as the control rotation.
var control_yaw := 0.0

var gait := Gait.RUN
var stance := Stance.STAND
var movement_mode := MovementMode.ON_GROUND
var velocity_cm := Vector3.ZERO        # Unreal axes not needed: Godot axes, cm/s
var acceleration_cm := Vector3.ZERO    # current acceleration (input * max acceleration)
var max_acceleration := 800.0
var braking_deceleration := 500.0
var ground_friction := 5.0
var max_speed := 500.0
var orient_to_movement := false
## Capsule yaw (radians); forward is (sin yaw, 0, cos yaw).
var yaw := 0.0
var just_landed := false
var land_velocity := Vector3.ZERO
## Slide state: time since the slide started (InitialBoost lasts SLIDE_INITIAL_BOOST_TIME), the
## mode's MaxSpeedOverride (kept between slides like the mode object's property), its smooth
## walking state and angular velocity (rad/s about up).
var slide_time := 0.0
var slide_max_speed_override := -1.0
var slide_walking = SMOOTH_WALKING.new()
var slide_angular_velocity := 0.0

var _capsule: CollisionShape3D


func _ready() -> void:
	_capsule = CollisionShape3D.new()
	var shape := CapsuleShape3D.new()
	shape.radius = CAPSULE_RADIUS * CM
	shape.height = CAPSULE_HALF_HEIGHT * 2.0 * CM
	_capsule.shape = shape
	_capsule.position.y = CAPSULE_HALF_HEIGHT * CM
	add_child(_capsule)
	floor_snap_length = 0.45  # MaxStepHeight 45 cm
	floor_max_angle = deg_to_rad(44.8)


func forward() -> Vector3:
	return Vector3(sin(yaw), 0, cos(yaw))


func speed_2d() -> float:
	return Vector2(velocity_cm.x, velocity_cm.z).length()


func is_falling() -> bool:
	return movement_mode == MovementMode.IN_AIR


## One movement tick: PreCMCTick (rotation flags, gait, speeds), then the movement component.
func tick(dt: float) -> void:
	just_landed = false
	_update_rotation_pre_cmc()
	_update_movement_pre_cmc()
	var input3 := Vector3(move_input.x, 0, move_input.y)
	var analog := clampf(input3.length(), 0.0, 1.0)
	acceleration_cm = input3.normalized() * max_acceleration * analog if input3.length() > 0.0 else Vector3.ZERO
	if movement_mode == MovementMode.SLIDING:
		_slide(dt, input3)
	elif movement_mode == MovementMode.ON_GROUND:
		_calc_velocity(dt, ground_friction, braking_deceleration, analog)
		velocity_cm.y = 0.0
	else:
		_fall(dt)
	if movement_mode != MovementMode.SLIDING:
		_rotate(dt)
	velocity = velocity_cm * CM
	move_and_slide()
	# Collisions change the velocity; keep it (in cm) for the next tick.
	var was_falling := movement_mode == MovementMode.IN_AIR
	if is_on_floor():
		if was_falling:
			just_landed = true
			land_velocity = velocity_cm
		velocity_cm = Vector3(velocity.x, 0, velocity.z) / CM
		if movement_mode == MovementMode.SLIDING:
			# BP_MovementTransition_FromSlide: uncrouched, or at most 200 cm/s.
			if stance != Stance.CROUCH or speed_2d() <= SLIDE_EXIT_SPEED:
				movement_mode = MovementMode.ON_GROUND
				# The crouch press only started the slide: come out of it standing, as before it.
				wants_to_crouch = false
				stance = Stance.STAND
		else:
			movement_mode = MovementMode.ON_GROUND
			# BP_MovementTransition_ToSlide: crouching above 380 cm/s.
			if stance == Stance.CROUCH and speed_2d() > SLIDE_ENTER_SPEED:
				_start_slide()
	else:
		movement_mode = MovementMode.IN_AIR
		velocity_cm = velocity / CM


func jump() -> void:
	if movement_mode == MovementMode.SLIDING:  # the Mover pawn's jump while sliding uncrouches
		wants_to_crouch = false
		return
	if movement_mode == MovementMode.ON_GROUND:
		velocity_cm.y = JUMP_Z_VELOCITY
		movement_mode = MovementMode.IN_AIR


func is_sliding() -> bool:
	return movement_mode == MovementMode.SLIDING


func _start_slide() -> void:
	movement_mode = MovementMode.SLIDING
	slide_time = 0.0
	slide_angular_velocity = 0.0
	slide_walking.initialized = false  # the smooth walking state starts over after another mode


## BP_MovementMode_Slide.GenerateWalkMove, then USmoothWalkingMode::GenerateWalkMove.
func _slide(dt: float, input3: Vector3) -> void:
	var r := _slide_step(dt, slide_walking, input3, velocity_cm, yaw, slide_angular_velocity, slide_time,
		slide_max_speed_override, get_floor_normal() if is_on_floor() else Vector3.UP)
	velocity_cm = r[0]
	slide_angular_velocity = r[1]
	slide_max_speed_override = r[2]
	slide_time += dt
	yaw = wrapf(yaw + slide_angular_velocity * dt, -PI, PI)
	velocity_cm.y = 0.0


## One slide step. Returns [velocity, angular velocity, MaxSpeedOverride]. The trajectory predictor
## steps a copy of the smooth walking state with it.
func _slide_step(dt: float, walking, input3: Vector3, vel: Vector3, cur_yaw: float, ang_vel: float,
		time: float, override: float, floor_normal: Vector3) -> Array:
	var boost := time < SLIDE_INITIAL_BOOST_TIME  # InitialBoost: set on activation, cleared after a delay
	var mi := input3.normalized() if input3.length() > 0.0 else Vector3.ZERO
	# SimpleWalkingMode builds the desired velocity before the blueprint sets this tick's override.
	var desired := mi * (override if override >= 0.0 else SLIDE_LEGACY_MAX_SPEED)
	var dir := desired.normalized() if desired.length_squared() > 1e-8 else Vector3.ZERO
	var slope := rad_to_deg(acos(clampf(floor_normal.dot(dir), -1.0, 1.0))) - 90.0
	var next_override := SLIDE_INITIAL_BOOST_SPEED
	if not boost:
		if slope > -SLIDE_SHALLOW_SLOPE_ANGLE:
			next_override = SLIDE_FLAT_GROUND_SPEED
		else:
			next_override = _map_clamped(slope, -SLIDE_SHALLOW_SLOPE_ANGLE, -SLIDE_STEEP_SLOPE_ANGLE, SLIDE_SHALLOW_SLOPE_SPEED, SLIDE_STEEP_SLOPE_SPEED)
	var p: Dictionary = SLIDE_WALK_PARAMS.duplicate()
	p["acceleration"] = SLIDE_INITIAL_BOOST_ACCELERATION if boost else SLIDE_AFTER_BOOST_ACCELERATION
	p["deceleration"] = _map_clamped(slope, SLIDE_SHALLOW_SLOPE_ANGLE, SLIDE_STEEP_SLOPE_ANGLE, SLIDE_FLAT_GROUND_DECELERATION, SLIDE_STEEP_SLOPE_DECELERATION)
	# Desired facing: where it moves, or the camera when strafing (the CMC's facing rules).
	var desired_yaw := cur_yaw
	if not orient_to_movement:
		desired_yaw = control_yaw
	elif mi != Vector3.ZERO:
		desired_yaw = atan2(mi.x, mi.z)
	var r: Array = walking.generate_walk_move(dt, p, desired, desired_yaw, cur_yaw, ang_vel, Vector3(vel.x, 0, vel.z))
	return [r[0], r[1], next_override]


## The slide ahead with this tick's input held (Mover's GetPredictedTrajectory steps a copy of the
## sync state): [velocity, yaw] every `step` seconds, up to `count` samples, until it would end.
func predict_slide(count: int, step: float) -> Array:
	var walking = slide_walking.copy()
	var vel := velocity_cm
	var cur := yaw
	var w := slide_angular_velocity
	var t := slide_time
	var override := slide_max_speed_override
	var n := get_floor_normal() if is_on_floor() else Vector3.UP
	var input3 := Vector3(move_input.x, 0, move_input.y)
	var out := []
	for i in count:
		var r := _slide_step(step, walking, input3, vel, cur, w, t, override, n)
		vel = r[0]
		w = r[1]
		override = r[2]
		t += step
		cur = wrapf(cur + w * step, -PI, PI)
		out.append([vel, cur])
		if Vector2(vel.x, vel.z).length() <= SLIDE_EXIT_SPEED:
			break  # FromSlide ends it here
	return out


# UpdateRotation_PreCMC: strafe/aim faces the camera, otherwise faces where it moves.
func _update_rotation_pre_cmc() -> void:
	orient_to_movement = not (wants_to_strafe or wants_to_aim)


# UpdateMovement_PreCMC: gait, acceleration, braking, friction, max speed.
func _update_movement_pre_cmc() -> void:
	gait = _desired_gait()
	stance = Stance.CROUCH if wants_to_crouch else Stance.STAND
	var s2d := speed_2d()
	max_acceleration = 800.0 if gait != Gait.SPRINT else _map_clamped(s2d, 300, 700, 800, 300)
	braking_deceleration = 500.0 if move_input.length() > 0.0 else 2000.0
	ground_friction = 5.0 if gait != Gait.SPRINT else _map_clamped(s2d, 0, 500, 5, 3)
	var speeds := CROUCH_SPEEDS if stance == Stance.CROUCH else ([WALK_SPEEDS, RUN_SPEEDS, SPRINT_SPEEDS][gait] as Vector3)
	var strafe_map := 0.0
	if not orient_to_movement:
		strafe_map = _strafe_map(absf(_direction_degrees()))
	max_speed = _map_clamped(strafe_map, 0, 1, speeds.x, speeds.y) if strafe_map < 1.0 else _map_clamped(strafe_map, 1, 2, speeds.y, speeds.z)


func _desired_gait() -> Gait:
	var full_input := true  # MovementStickMode 0: fixed speed, single gait
	if _can_sprint():
		return Gait.SPRINT if full_input else Gait.RUN
	if wants_to_walk:
		return Gait.WALK
	return Gait.RUN if full_input else Gait.WALK


func _can_sprint() -> bool:
	if not wants_to_sprint:
		return false
	if orient_to_movement:
		return true
	if move_input.length() == 0.0:
		return false
	var input_yaw := atan2(move_input.x, move_input.y)
	return absf(rad_to_deg(wrapf(input_yaw - yaw, -PI, PI))) < 50.0


# Signed angle (degrees) of the velocity relative to the capsule's facing (CalculateDirection).
func _direction_degrees() -> float:
	if speed_2d() < 1e-3:
		return 0.0
	return rad_to_deg(wrapf(atan2(velocity_cm.x, velocity_cm.z) - yaw, -PI, PI))


static func _strafe_map(deg: float) -> float:
	for i in range(1, STRAFE_MAP_KEYS.size()):
		var a: Vector2 = STRAFE_MAP_KEYS[i - 1]
		var b: Vector2 = STRAFE_MAP_KEYS[i]
		if deg <= b.x:
			return lerpf(a.y, b.y, (deg - a.x) / (b.x - a.x))
	return 2.0


static func _map_clamped(v: float, in_a: float, in_b: float, out_a: float, out_b: float) -> float:
	return lerpf(out_a, out_b, clampf((v - in_a) / (in_b - in_a), 0.0, 1.0))


# CharacterMovementComponent::CalcVelocity (walking).
func _calc_velocity(dt: float, friction: float, braking: float, analog: float) -> void:
	var max_input_speed := maxf(max_speed * analog, MIN_ANALOG_WALK_SPEED)
	var zero_accel := acceleration_cm.is_zero_approx()
	var over_max := velocity_cm.length_squared() > max_input_speed * max_input_speed * 1.01
	if zero_accel or over_max:
		var old := velocity_cm
		_apply_braking(dt, friction, braking)
		if over_max and velocity_cm.length_squared() < max_input_speed * max_input_speed and acceleration_cm.dot(old) > 0.0:
			velocity_cm = old.normalized() * max_input_speed
	elif not zero_accel:
		var dir := acceleration_cm.normalized()
		var size := velocity_cm.length()
		velocity_cm = velocity_cm - (velocity_cm - dir * size) * minf(dt * friction, 1.0)
	if not zero_accel:
		var new_max := velocity_cm.length() if velocity_cm.length_squared() > max_input_speed * max_input_speed * 1.01 else max_input_speed
		velocity_cm += acceleration_cm * dt
		velocity_cm = velocity_cm.limit_length(new_max)


# CharacterMovementComponent::ApplyVelocityBraking.
func _apply_braking(dt: float, friction: float, braking: float) -> void:
	if velocity_cm.is_zero_approx():
		return
	friction = maxf(0.0, friction * maxf(0.0, BRAKING_FRICTION_FACTOR))
	braking = maxf(0.0, braking)
	if friction == 0.0 and braking == 0.0:
		return
	var old := velocity_cm
	var remaining := dt
	var max_step := clampf(BRAKING_SUBSTEP, 1.0 / 75.0, 1.0 / 20.0)
	var rev := -braking * velocity_cm.normalized() if braking > 0.0 else Vector3.ZERO
	while remaining >= 1e-6:
		var step := minf(max_step, remaining * 0.5) if (remaining > max_step and friction != 0.0) else remaining
		remaining -= step
		velocity_cm = velocity_cm + (-friction * velocity_cm + rev) * step
		if velocity_cm.dot(old) <= 0.0:
			velocity_cm = Vector3.ZERO
			return
	if velocity_cm.length_squared() <= 1e-4 or (braking > 0.0 and velocity_cm.length_squared() <= BRAKE_TO_STOP_VELOCITY * BRAKE_TO_STOP_VELOCITY):
		velocity_cm = Vector3.ZERO


func _fall(dt: float) -> void:
	# Lateral: air control scales the acceleration; no friction or braking while falling (defaults).
	var lateral := Vector3(velocity_cm.x, 0, velocity_cm.z)
	if not acceleration_cm.is_zero_approx():
		lateral += acceleration_cm * AIR_CONTROL * dt
		lateral = lateral.limit_length(maxf(max_speed, Vector2(velocity_cm.x, velocity_cm.z).length()))
	velocity_cm = Vector3(lateral.x, velocity_cm.y - GRAVITY * dt, lateral.z)


# RotationRate: -1 on the ground (instant), 200 deg/s in the air.
func _rotate(dt: float) -> void:
	var target := yaw
	if orient_to_movement:
		if not acceleration_cm.is_zero_approx():
			target = atan2(acceleration_cm.x, acceleration_cm.z)
	else:
		target = control_yaw
	if movement_mode == MovementMode.ON_GROUND:
		yaw = target
	else:
		yaw += clampf(wrapf(target - yaw, -PI, PI), -deg_to_rad(200.0) * dt, deg_to_rad(200.0) * dt)


## What the anim blueprint reads from the pawn (S_CharacterPropertiesForAnimation), in cm.
func properties() -> Dictionary:
	return {
		"movement_mode": movement_mode, "stance": stance, "gait": gait,
		"rotation_mode": 0 if orient_to_movement else 1,
		"velocity": velocity_cm, "input_acceleration": acceleration_cm,
		"max_acceleration": max_acceleration, "max_deceleration": braking_deceleration,
		"yaw": yaw, "control_yaw": control_yaw, "wants_to_aim": wants_to_aim,
		"just_landed": just_landed, "land_velocity": land_velocity,
	}
