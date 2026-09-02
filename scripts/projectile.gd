class_name Projectile
extends Node3D

## A traveling ranged-weapon shot (see Blocks.WEAPON_SHAPES, hit_style
## "projectile"). Deliberately its own lightweight thing rather than a
## RigidBody -- just linear motion plus a swept raycast each physics tick
## (so it can't tunnel through a creature at speed), matching the low-poly
## box-mesh aesthetic used everywhere else in this game.

var velocity := Vector3.ZERO
var damage := 0.0
var stagger := 0.0
var max_range := 30.0
var _traveled := 0.0


func launch(from: Vector3, dir: Vector3, speed: float, dmg: float, stag: float, rng: float) -> void:
	global_position = from
	var d := dir.normalized()
	velocity = d * speed
	damage = dmg
	stagger = stag
	max_range = rng
	var up := Vector3.UP if absf(d.dot(Vector3.UP)) < 0.99 else Vector3.RIGHT
	look_at(from + d, up)
	_build_mesh()


func _build_mesh() -> void:
	var mi := MeshInstance3D.new()
	var m := BoxMesh.new()
	m.size = Vector3(0.08, 0.08, 0.4)
	mi.mesh = m
	var mat := StandardMaterial3D.new()
	mat.albedo_color = Color(0.4, 0.9, 1.0)
	mat.emission_enabled = true
	mat.emission = Color(0.4, 0.9, 1.0)
	mat.emission_energy_multiplier = 3.0
	mi.material_override = mat
	add_child(mi)


func _physics_process(delta: float) -> void:
	var from := global_position
	var step := velocity * delta
	var to := from + step
	if step.length() > 0.001:
		var space := get_world_3d().direct_space_state
		var query := PhysicsRayQueryParameters3D.create(from, to)
		var hit := space.intersect_ray(query)
		if not hit.is_empty() and hit.get("collider") is Creature:
			hit["collider"].take_hit(damage, stagger)
			queue_free()
			return
	global_position = to
	_traveled += step.length()
	if _traveled >= max_range:
		queue_free()
