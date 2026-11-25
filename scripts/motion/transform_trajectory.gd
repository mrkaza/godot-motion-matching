# Unreal's PoseSearchGenerateTransformTrajectory + HandleTransformTrajectoryWorldCollisions, as the
# sample's anim blueprint calls them (Update_Trajectory):
# 30 history samples taken every frame, the current sample at +dt, and 15 predicted samples 0.1 s
# apart from Unreal's character-movement ground step (PoseSearchTrajectoryLibrary.cpp).
# Units: positions in metres (Godot world), velocities in cm/s like GaspCharacter. Facing is a yaw
# (radians, forward = (sin, 0, cos)).
class_name TransformTrajectory
extends RefCounted

const HISTORY_COUNT := 30
const PREDICTION_COUNT := 15
const PREDICTION_INTERVAL := 0.1
const HISTORY_INTERVAL := -1.0       # <= 0: shift every frame
const MAX_OBSTACLE_HEIGHT := 1.5     # m
const FLOOR_OFFSET := 0.0001         # 0.01 cm
const BRAKING_SUBSTEP := 1.0 / 33.0
const BRAKE_TO_STOP := 10.0
const CM := 0.01

# TrajectoryGenerationData_Idle / _Moving (anim blueprint class defaults).
const IDLE := {"rotate_towards_movement_speed": 0.0, "max_controller_yaw_rate": 100.0}
const MOVING := {"rotate_towards_movement_speed": 0.0, "max_controller_yaw_rate": 0.0}

var times := PackedFloat32Array()
var positions := PackedVector3Array()
var facings := PackedFloat32Array()
var time_to_land := 0.0
var _last_controller_yaw := NAN


func sample_count() -> int:
	return times.size()


## One update. `c` is the GaspCharacter; `speed_2d_last_frame` picks Idle or Moving settings
## (the blueprint runs this before it updates Speed2D).
func update(c: GaspCharacter, dt: float, speed_2d_last_frame: float, world: World3D) -> void:
	var data: Dictionary = MOVING if speed_2d_last_frame > 0.0 else IDLE
	var position := c.global_position
	var facing := c.yaw if c.orient_to_movement else c.control_yaw
	var total := HISTORY_COUNT + 1 + PREDICTION_COUNT
	if times.size() != total:
		times.resize(total)
		positions.resize(total)
		facings.resize(total)
		for i in total:
			positions[i] = position
			facings[i] = facing
			times[i] = maxf(HISTORY_INTERVAL, 0.0) * (i - HISTORY_COUNT - 1) if i < HISTORY_COUNT else PREDICTION_INTERVAL * (i - HISTORY_COUNT) + dt

	# Controller yaw rate (UpdateData).
	var yaw_deg := rad_to_deg(c.control_yaw)
	var yaw_rate := 0.0
	if not is_nan(_last_controller_yaw) and dt > 1e-8:
		yaw_rate = wrapf(yaw_deg - _last_controller_yaw, -180.0, 180.0) / dt
		var max_rate: float = data["max_controller_yaw_rate"]
		if max_rate >= 0.0:
			yaw_rate = signf(yaw_rate) * minf(absf(yaw_rate), max_rate)
	_last_controller_yaw = yaw_deg

	_update_history(position, c.velocity_cm, dt)
	_predict(c, data, position, facing, yaw_rate, dt)
	_collide(c, world)


func _update_history(position: Vector3, velocity_cm: Vector3, dt: float) -> void:
	var n := HISTORY_COUNT
	var ground := (position - positions[n]) - velocity_cm * CM * dt
	var shift := times[n]
	for i in n - 1:
		times[i] = times[i + 1] - shift
		positions[i] = positions[i + 1] + ground
		facings[i] = facings[i + 1]
	times[n - 1] = 0.0
	positions[n - 1] = positions[n] + ground
	facings[n - 1] = facings[n]


func _predict(c: GaspCharacter, data: Dictionary, position: Vector3, facing: float, yaw_rate: float, dt: float) -> void:
	var pos := position
	var vel := c.velocity_cm
	var acc := c.acceleration_cm
	var face := facing
	var max_speed := maxf(c.max_speed, GaspCharacter.MIN_ANALOG_WALK_SPEED)
	var friction := c.ground_friction
	if acc.is_zero_approx():
		friction = maxf(0.0, c.ground_friction * maxf(0.0, GaspCharacter.BRAKING_FRICTION_FACTOR))
	var braking := maxf(0.0, c.braking_deceleration)
	var step_ground := not c.is_falling()
	var yaw_step := deg_to_rad(yaw_rate * PREDICTION_INTERVAL)
	var t := dt
	var last := times.size() - 1
	var i := HISTORY_COUNT
	# Sliding (the Mover slide): the slide mode steps the prediction, like Mover's predicted
	# trajectory; once it would end, the velocity is held.
	var slide: Array = c.predict_slide(last - HISTORY_COUNT, PREDICTION_INTERVAL) if c.is_sliding() else []
	if c.is_sliding():
		while true:
			positions[i] = pos
			facings[i] = face
			times[i] = t
			if i == last:
				break
			pos += vel * CM * PREDICTION_INTERVAL
			t += PREDICTION_INTERVAL
			var k := i - HISTORY_COUNT
			if k < slide.size():
				vel = slide[k][0]
				face = slide[k][1]
			i += 1
		return
	while true:
		positions[i] = pos
		facings[i] = face
		times[i] = t
		if i == last:
			break
		pos += vel * CM * PREDICTION_INTERVAL
		t += PREDICTION_INTERVAL
		if step_ground:
			acc = acc.rotated(Vector3.UP, yaw_step)
			vel = _ground_step(PREDICTION_INTERVAL, vel, acc, friction, braking, max_speed)
			face += yaw_step
			if c.orient_to_movement and not acc.is_zero_approx():
				var target := atan2(acc.x, acc.z)
				var speed: float = data["rotate_towards_movement_speed"]
				# QInterpConstantTo returns the target when the speed is <= 0.
				face = target if speed <= 0.0 else face + clampf(wrapf(target - face, -PI, PI), -speed * PREDICTION_INTERVAL, speed * PREDICTION_INTERVAL)
		i += 1


# FPoseSearchTrajectoryData::StepCharacterMovementGroundPrediction.
static func _ground_step(dt: float, vel: Vector3, acc: Vector3, friction: float, braking: float, max_speed: float) -> Vector3:
	var out := vel
	if acc.is_zero_approx():
		if vel.is_zero_approx():
			return Vector3.ZERO
		if friction == 0.0 and braking == 0.0:
			return vel
		var remaining := dt
		var max_step := clampf(BRAKING_SUBSTEP, 1.0 / 75.0, 1.0 / 20.0)
		var prev := out
		var rev := -braking * out.normalized() if braking > 0.0 else Vector3.ZERO
		while remaining >= 1e-6:
			var step := minf(max_step, remaining * 0.5) if (remaining > max_step and friction != 0.0) else remaining
			remaining -= step
			out = out + (-friction * out + rev) * step
			if out.dot(prev) <= 0.0:
				return Vector3.ZERO
		if out.length_squared() <= 1e-4 or (braking > 0.0 and out.length_squared() <= BRAKE_TO_STOP * BRAKE_TO_STOP):
			return Vector3.ZERO
		return out
	var dir := acc.normalized()
	var size := out.length()
	out = out - (out - dir * size) * minf(dt * friction, 1.0)
	out += acc * dt
	return out.limit_length(max_speed)


# HandleTransformTrajectoryWorldCollisionsWithGravity (bApplyGravity on).
func _collide(c: GaspCharacter, world: World3D) -> void:
	time_to_land = times[times.size() - 1]
	var space := world.direct_space_state
	var g := GaspCharacter.GRAVITY * CM
	var vz := c.velocity_cm.y * CM
	var free_fall := 0.0
	var landed := false
	var first_fall := true
	var start_y: float = (sample_at(0.0)[0] as Vector3).y
	for i in range(1, times.size()):
		if times[i] <= 0.0:
			continue
		free_fall += times[i] - times[i - 1]
		var p := positions[i]
		if landed:
			p.y = positions[i - 1].y
		p.y -= 0.5 * g * free_fall * free_fall
		var query := PhysicsRayQueryParameters3D.create(p + Vector3.UP * MAX_OBSTACLE_HEIGHT, p)
		query.exclude = [c.get_rid()]
		query.collision_mask = 1  # world only, not the ragdoll's bodies
		var hit := space.intersect_ray(query)
		if not hit.is_empty():
			p.y = hit["position"].y + FLOOR_OFFSET
			landed = true
			if first_fall:
				first_fall = false
				var fall := absf(p.y - start_y)
				time_to_land = (vz / g) + sqrt(vz * vz + 2.0 * g * fall) / g
			free_fall = 0.0
		positions[i] = p


## [position, facing] at a time (linear between samples, clamped at the ends).
func sample_at(t: float) -> Array:
	var n := times.size()
	if n == 0:
		return [Vector3.ZERO, 0.0]
	if t <= times[0]:
		return [positions[0], facings[0]]
	for i in range(1, n):
		if t <= times[i]:
			var a := (t - times[i - 1]) / maxf(times[i] - times[i - 1], 1e-6)
			return [positions[i - 1].lerp(positions[i], a), lerp_angle(facings[i - 1], facings[i], a)]
	return [positions[n - 1], facings[n - 1]]


## Average velocity (cm/s) between two times (GetTransformTrajectoryVelocity).
func velocity_between(t0: float, t1: float) -> Vector3:
	return (sample_at(t1)[0] - sample_at(t0)[0]) / maxf(t1 - t0, 1e-6) / CM
