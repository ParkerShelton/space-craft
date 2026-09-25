class_name SpitGlob
extends Node3D
## What a Night Stalker spits: it arcs, and it is thrown ahead of where you are
## going. What it does when it lands is the `kind` its species spits --
## "web" sticks you fast (see Player.webbed), "fire" sets you burning, "stone"
## is a rock that simply hurts and knocks you back.

## Lighter than real gravity, so the arc is readable and can be sidestepped.
const GRAVITY_SCALE := 0.55
const HIT_RADIUS := 0.85
const LIFE := 5.0
const C_GOO := Color(0.82, 0.9, 0.72)
const C_FIRE := Color(1.0, 0.55, 0.12)
const C_STONE := Color(0.5, 0.48, 0.46)

## What this glob is: "web", "fire" or "stone". Set before launch.
var kind := "web"
var vel := Vector3.ZERO
var world: WorldManager
var _life := LIFE
var _exclude: Array[RID] = []
var _core: Node3D


func launch(from: Vector3, v: Vector3, w: WorldManager, shooter: CollisionObject3D) -> void:
	world = w
	vel = v
	if shooter != null:
		_exclude.append(shooter.get_rid())
	_build()
	global_position = from


## Where to throw from `from` so a glob moving at `speed` meets a target at
## `target` moving at `target_vel` -- led, and lifted for the drop.
static func aim(from: Vector3, target: Vector3, target_vel: Vector3, speed: float, g: Vector3) -> Vector3:
	var t := clampf(from.distance_to(target) / speed, 0.25, 1.6)
	var at := target + target_vel * t * 0.8
	t = clampf(from.distance_to(at) / speed, 0.25, 1.6)
	return (at - from) / t - g * GRAVITY_SCALE * t * 0.5


func _build() -> void:
	_core = Node3D.new()
	add_child(_core)
	var m := StandardMaterial3D.new()
	m.albedo_color = _colour()
	m.emission_enabled = true
	m.emission = _colour()
	m.emission_energy_multiplier = 2.5 if kind == "fire" else (0.0 if kind == "stone" else 0.8)
	for b in [[Vector3(0.28, 0.28, 0.28), Vector3.ZERO], [Vector3(0.16, 0.16, 0.16), Vector3(0.14, 0.1, 0.05)],
			[Vector3(0.14, 0.14, 0.14), Vector3(-0.12, -0.08, 0.1)], [Vector3(0.1, 0.1, 0.1), Vector3(0.02, -0.15, -0.12)]]:
		var mi := MeshInstance3D.new()
		var bm := BoxMesh.new()
		bm.size = b[0]
		mi.mesh = bm
		mi.material_override = m
		mi.position = b[1]
		_core.add_child(mi)
	# Strings of it trailing behind.
	var tr := CPUParticles3D.new()
	var dm := BoxMesh.new()
	dm.size = Vector3.ONE * 0.05
	var tm := StandardMaterial3D.new()
	tm.albedo_color = _colour()
	tm.shading_mode = BaseMaterial3D.SHADING_MODE_UNSHADED
	dm.material = tm
	tr.mesh = dm
	tr.amount = 24
	tr.lifetime = 0.5
	tr.local_coords = false
	tr.spread = 180.0
	tr.initial_velocity_min = 0.1
	tr.initial_velocity_max = 0.4
	tr.gravity = Vector3.ZERO
	add_child(tr)


func _colour() -> Color:
	match kind:
		"fire": return C_FIRE
		"stone": return C_STONE
	return C_GOO


## What it does to you. Each kind hurts, and then has its own idea besides.
func _land_on(pl) -> void:
	# Through the world, so it lands on whichever player it hit -- this
	# machine's or someone else's (see WorldManager.hurt).
	match kind:
		"fire":
			world.hurt(pl, 4.0, Vector3.ZERO, "ignite")
		"stone":
			# A rock this size shoves you off your feet.
			var up := -world.gravity_at((pl as Node3D).global_position).normalized()
			world.hurt(pl, 9.0, vel.normalized() * 7.0 + up * 4.0)
		_:
			world.hurt(pl, 3.0, Vector3.ZERO, "web")


func _physics_process(delta: float) -> void:
	if world == null:
		queue_free()
		return
	vel += world.gravity_at(global_position) * GRAVITY_SCALE * delta
	var from := global_position
	var to := from + vel * delta
	_core.rotate(Vector3(0.3, 1.0, 0.2).normalized(), delta * 9.0)
	for pl in world.player_nodes():
		# Closest point of this frame's path to you, so a fast glob cannot pass
		# through you between frames.
		var c: Vector3 = (pl as Node3D).global_position
		var seg := to - from
		var t := clampf((c - from).dot(seg) / maxf(seg.length_squared(), 0.0001), 0.0, 1.0)
		if (from + seg * t).distance_to(c) < HIT_RADIUS:
			_land_on(pl)
			_splat(from + seg * t)
			return
		if pl is CollisionObject3D and not _exclude.has((pl as CollisionObject3D).get_rid()):
			_exclude.append((pl as CollisionObject3D).get_rid())
	var q := PhysicsRayQueryParameters3D.create(from, to, 1)
	q.exclude = _exclude
	var hit := get_world_3d().direct_space_state.intersect_ray(q)
	if not hit.is_empty():
		_splat(hit["position"])
		return
	global_position = to
	_life -= delta
	if _life <= 0.0:
		queue_free()


## Burst into strands where it landed.
func _splat(at: Vector3) -> void:
	var ps := CPUParticles3D.new()
	var dm := BoxMesh.new()
	dm.size = Vector3(0.04, 0.04, 0.22)
	var tm := StandardMaterial3D.new()
	tm.albedo_color = _colour()
	if kind == "fire":
		tm.shading_mode = BaseMaterial3D.SHADING_MODE_UNSHADED
	dm.material = tm
	ps.mesh = dm
	ps.one_shot = true
	ps.explosiveness = 1.0
	ps.amount = 26
	ps.lifetime = 0.7
	ps.spread = 180.0
	ps.initial_velocity_min = 1.5
	ps.initial_velocity_max = 4.0
	ps.gravity = world.gravity_at(at) * 0.5 if world != null else Vector3.DOWN * 5.0
	ps.particle_flag_align_y = true
	# Emitting only once it is in place: a one-shot CPUParticles3D fires its
	# batch with the transform it had BEFORE it was moved, which was the
	# world's origin (see Player._emit_at).
	ps.emitting = false
	get_parent().add_child(ps)
	ps.global_position = at
	ps.set_deferred("emitting", true)
	get_tree().create_timer(1.2).timeout.connect(ps.queue_free)
	queue_free()
