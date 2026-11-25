# Unreal 5.8 Mover's USmoothWalkingMode::GenerateWalkMove (Plugins/Experimental/Mover/Source/Mover/
# Private/DefaultMovementSet/Modes/SmoothWalkingMode.cpp:37-202) and the SpringMath helpers it uses
# (Core/Public/Math/SpringMath.h:157, 173-193, 236-257; UnrealMathUtility.h:1553-1588), on yaw-only
# facing. Units: cm, cm/s, radians for facing. The state is a plain object so the trajectory
# predictor can copy it and step it ahead (MoverComponent.cpp:2344 GetPredictedTrajectory copies the
# sync state, which holds FSmoothWalkingState).
class_name SmoothWalking
extends RefCounted

const UE_SMALL_NUMBER := 1e-8
const UE_KINDA_SMALL_NUMBER := 1e-4

# FSmoothWalkingState.
var spring_velocity := Vector3.ZERO
var spring_acceleration := Vector3.ZERO
var intermediate_velocity := Vector3.ZERO
var intermediate_facing := 0.0
var intermediate_angular_velocity := 0.0
var initialized := false


func copy() -> SmoothWalking:
	var c := SmoothWalking.new()
	c.spring_velocity = spring_velocity
	c.spring_acceleration = spring_acceleration
	c.intermediate_velocity = intermediate_velocity
	c.intermediate_facing = intermediate_facing
	c.intermediate_angular_velocity = intermediate_angular_velocity
	c.initialized = initialized
	return c


static func inv_exp_approx(x: float) -> float:
	return 1.0 / (1.0 + 1.00746054 * x + 0.45053901 * x * x + 0.25724632 * x * x * x)


static func exponential_smoothing(value, target, dt: float, smoothing_time: float):
	if smoothing_time > UE_KINDA_SMALL_NUMBER:
		return target + (value - target) * inv_exp_approx(dt / smoothing_time)
	return target


static func strength_to_smoothing_time(strength: float) -> float:
	return 2.0 / maxf(strength, UE_SMALL_NUMBER)


## SpringMath::CriticalSpringDamper on a Vector3: returns [x, v].
static func critical_spring(x: Vector3, v: Vector3, target: Vector3, smoothing_time: float, dt: float) -> Array:
	if smoothing_time < UE_SMALL_NUMBER:
		return [target, Vector3.ZERO]
	var y := 4.0 / smoothing_time / 2.0  # SmoothingTimeToDamping / 2
	var j0 := x - target
	var j1 := v + j0 * y
	var eydt := inv_exp_approx(y * dt)
	return [eydt * (j0 + j1 * dt) + target, eydt * (v - j1 * y * dt)]


## SpringMath::CriticalSpringDamperQuat for a rotation about up: returns [yaw, angular velocity].
static func critical_spring_yaw(yaw: float, w: float, target: float, smoothing_time: float, dt: float) -> Array:
	if smoothing_time < UE_SMALL_NUMBER:
		return [target, 0.0]
	var y := 4.0 / smoothing_time / 2.0
	var j0 := wrapf(yaw - target, -PI, PI)
	var j1 := w + j0 * y
	var eydt := inv_exp_approx(y * dt)
	return [wrapf(eydt * (j0 + j1 * dt) + target, -PI, PI), eydt * (w - j1 * y * dt)]


## One GenerateWalkMove. `p` holds the mode's settings (acceleration, deceleration, turning_strength,
## directional_acceleration_factor, acceleration/deceleration smoothing time and compensation,
## outside_influence_smoothing_time, velocity/acceleration/facing/angular deadzones, facing_smoothing_time,
## double_spring). Velocity in cm/s (xz plane), facing yaw in radians, angular velocity in rad/s.
## Returns [velocity, angular_velocity].
func generate_walk_move(dt: float, p: Dictionary, desired_velocity: Vector3, desired_facing: float,
		current_facing: float, angular_velocity: float, velocity: Vector3) -> Array:
	if dt <= 1e-7:
		return [velocity, angular_velocity]
	if not initialized:
		spring_velocity = velocity
		spring_acceleration = Vector3.ZERO
		intermediate_velocity = velocity
		intermediate_facing = current_facing
		intermediate_angular_velocity = 0.0
		initialized = true
	var velocity_match := clampf(spring_velocity.dot(velocity) / maxf(velocity.length() * spring_velocity.length(), UE_SMALL_NUMBER), 0.0, 1.0)
	intermediate_velocity = exponential_smoothing(intermediate_velocity, velocity, dt,
		(float(p["outside_influence_smoothing_time"]) + UE_KINDA_SMALL_NUMBER) / (1.0 - velocity_match))
	spring_velocity = velocity
	var turning: float = p["turning_strength"]
	if turning > 0.0 and not desired_velocity.is_zero_approx():
		intermediate_velocity = exponential_smoothing(intermediate_velocity,
			desired_velocity.normalized() * intermediate_velocity.length(), dt, strength_to_smoothing_time(turning))
	var accelerating := 1.01 * desired_velocity.length_squared() > spring_velocity.length_squared()
	var accel: float = p["acceleration"]
	var dir_factor: float = p["directional_acceleration_factor"]
	var lateral_mag: float = (1.0 - dir_factor) * accel if accelerating else float(p["deceleration"])
	var directional_mag := dir_factor * accel if accelerating else 0.0
	var previous_length := intermediate_velocity.length()
	var difference := desired_velocity - intermediate_velocity
	var lateral := _safe_normal(difference) * minf(lateral_mag, difference.length() / maxf(dt, UE_SMALL_NUMBER))
	var directional := _safe_normal(desired_velocity) * directional_mag
	var desired_accel := lateral + directional
	var next_velocity := intermediate_velocity + desired_accel * dt if difference.dot(desired_accel * dt) < difference.length_squared() else desired_velocity
	next_velocity = next_velocity.limit_length(maxf(previous_length, desired_velocity.length()))
	var smoothing_time: float = p["acceleration_smoothing_time"] if accelerating else p["deceleration_smoothing_time"]
	var compensation: float = p["acceleration_smoothing_compensation"] if accelerating else p["deceleration_smoothing_compensation"]
	var lag := dt + compensation * smoothing_time
	var track := intermediate_velocity + desired_accel * lag if difference.dot(desired_accel * lag) < difference.length_squared() else desired_velocity
	track = track.limit_length(maxf(previous_length, desired_velocity.length()))
	var s := critical_spring(spring_velocity, spring_acceleration, track, smoothing_time, dt)
	spring_velocity = s[0]
	spring_acceleration = s[1]
	if (desired_velocity - spring_velocity).length_squared() < pow(float(p["velocity_deadzone"]), 2):
		spring_velocity = desired_velocity
		if spring_acceleration.length_squared() < pow(float(p["acceleration_deadzone"]), 2):
			spring_acceleration = Vector3.ZERO
	var out_velocity := spring_velocity
	intermediate_velocity = next_velocity

	var w := angular_velocity
	var updated := current_facing
	var facing_time: float = p["facing_smoothing_time"]
	if p.get("double_spring", false):
		var a := critical_spring_yaw(intermediate_facing, intermediate_angular_velocity, desired_facing, facing_time / 2.0, dt)
		intermediate_facing = a[0]
		intermediate_angular_velocity = a[1]
		var b := critical_spring_yaw(updated, w, intermediate_facing, facing_time / 2.0, dt)
		updated = b[0]
		w = b[1]
	else:
		intermediate_facing = desired_facing
		intermediate_angular_velocity = w
		var b := critical_spring_yaw(updated, w, desired_facing, facing_time, dt)
		updated = b[0]
		w = b[1]
	if absf(wrapf(desired_facing - updated, -PI, PI)) < deg_to_rad(float(p["facing_deadzone"])):
		w = wrapf(updated - current_facing, -PI, PI) / dt
		intermediate_facing = desired_facing
		if w * w < pow(deg_to_rad(float(p["angular_velocity_deadzone"])), 2):
			intermediate_angular_velocity = 0.0
	return [out_velocity, w]


static func _safe_normal(v: Vector3) -> Vector3:
	return v.normalized() if v.length_squared() > UE_SMALL_NUMBER else Vector3.ZERO
