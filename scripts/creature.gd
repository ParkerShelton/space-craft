class_name Creature
extends CharacterBody3D

## A procedurally-assembled blocky (Minecraft-style) creature. Body shape, size,
## color, and behavior are all generated per-planet from its seed (see
## Planet._derive_fauna/_make_species) instead of hand-modeled -- so what
## wildlife you find is as procedural as the ores. Built entirely from boxes,
## the same low-poly vertex-color aesthetic as the rest of the game.

var species: Dictionary = {}
var planet: Planet
var world: WorldManager

const GRAVITY_ACCEL := 14.0
const WANDER_MIN := 2.0
const WANDER_MAX := 5.0
const ATTACK_RANGE := 1.8
const ATTACK_COOLDOWN := 1.2
const ALIGN_SPEED := 3.0

var _wander_dir := Vector3.ZERO
var _wander_timer := 0.0
var _attack_cd := 0.0
var _phase := 0.0
var _legs: Array = []       # leg pivots (Node3D), animated for a walk cycle
var _tail_pivot: Node3D     # tail or fish tail-fin pivot, animated as a wag
var _segments: Array = []   # serpent body segments, animated as a wiggle
var _model: Node3D
var _health := 20.0


func configure(sp: Dictionary, p: Planet, w: WorldManager) -> void:
	species = sp
	planet = p
	world = w
	_health = float(sp.get("health", 20.0))
	_build_body()
	rotate_y(randf() * TAU)
	_build_collision()


func _build_collision() -> void:
	var scale_f: float = species.get("scale", 1.0)
	var cap := CollisionShape3D.new()
	var shape := CapsuleShape3D.new()
	shape.radius = 0.42 * scale_f
	shape.height = 1.5 * scale_f
	cap.shape = shape
	cap.position = Vector3(0, 0.75 * scale_f, 0)
	add_child(cap)


# --- body assembly (boxes only, per body plan) ---------------------------------

func _build_body() -> void:
	_model = Node3D.new()
	add_child(_model)
	var s: float = species.get("scale", 1.0)
	var color: Color = species.get("color", Color.WHITE)
	var accent: Color = species.get("accent", color)
	match species.get("body", "quad"):
		"quad": _build_quad(s, color, accent)
		"biped": _build_biped(s, color, accent)
		"serpent": _build_serpent(s, color, accent)
		"fish": _build_fish(s, color, accent)
		_: _build_quad(s, color, accent)


func _mk_box(parent: Node3D, size: Vector3, pos: Vector3, color: Color) -> MeshInstance3D:
	var mi := MeshInstance3D.new()
	var m := BoxMesh.new()
	m.size = size
	mi.mesh = m
	mi.position = pos
	var mat := StandardMaterial3D.new()
	mat.albedo_color = color
	mat.roughness = 0.9
	mi.material_override = mat
	parent.add_child(mi)
	return mi


func _mk_pivot(parent: Node3D, pos: Vector3) -> Node3D:
	var n := Node3D.new()
	n.position = pos
	parent.add_child(n)
	return n


func _build_quad(s: float, color: Color, accent: Color) -> void:
	var leg_len := 0.5 * s
	var torso := Vector3(0.85, 0.6, 1.5) * s
	var torso_y := leg_len + torso.y * 0.5
	_mk_box(_model, torso, Vector3(0, torso_y, 0), color)
	_mk_box(_model, Vector3(0.55, 0.5, 0.55) * s,
		Vector3(0, torso_y + torso.y * 0.15, -torso.z * 0.5 - 0.22 * s), accent)
	var hx := torso.x * 0.5 - 0.08 * s
	var hz := torso.z * 0.5 - 0.25 * s
	for sx in [-1, 1]:
		for sz in [-1, 1]:
			var pivot := _mk_pivot(_model, Vector3(sx * hx, leg_len, sz * hz))
			_mk_box(pivot, Vector3(0.22, leg_len, 0.22) * s, Vector3(0, -leg_len * 0.5, 0), accent)
			_legs.append(pivot)
	_tail_pivot = _mk_pivot(_model, Vector3(0, torso_y + torso.y * 0.1, torso.z * 0.5))
	_tail_pivot.rotation.x = -0.5
	_mk_box(_tail_pivot, Vector3(0.16, 0.16, 0.6) * s, Vector3(0, 0, 0.3 * s), color)


func _build_biped(s: float, color: Color, accent: Color) -> void:
	var leg_len := 0.6 * s
	var torso := Vector3(0.55, 0.85, 0.5) * s
	var torso_y := leg_len + torso.y * 0.5
	_mk_box(_model, torso, Vector3(0, torso_y, 0), color)
	_mk_box(_model, Vector3(0.45, 0.45, 0.45) * s, Vector3(0, torso_y + torso.y * 0.65, 0), accent)
	for sx in [-1, 1]:
		var pivot := _mk_pivot(_model, Vector3(sx * 0.18 * s, leg_len, 0))
		_mk_box(pivot, Vector3(0.2, leg_len, 0.24) * s, Vector3(0, -leg_len * 0.5, 0), accent)
		_legs.append(pivot)


func _build_serpent(s: float, color: Color, accent: Color) -> void:
	var n := 5
	var seg_len := 0.5 * s
	for i in n:
		var c := color if i % 2 == 0 else accent
		var sz := lerpf(0.55, 0.28, float(i) / float(n - 1)) * s
		var pos := Vector3(0, sz * 0.5, -float(i) * seg_len)
		_segments.append(_mk_box(_model, Vector3(sz, sz, seg_len * 1.05), pos, c))


func _build_fish(s: float, color: Color, accent: Color) -> void:
	var body := Vector3(0.34, 0.34, 1.0) * s
	_mk_box(_model, body, Vector3.ZERO, color)
	_tail_pivot = _mk_pivot(_model, Vector3(0, 0, body.z * 0.5))
	_mk_box(_tail_pivot, Vector3(0.06, 0.32, 0.35) * s, Vector3(0, 0, 0.17 * s), accent)
	for sx in [-1, 1]:
		_mk_box(_model, Vector3(0.05, 0.05, 0.28) * s, Vector3(sx * body.x * 0.6, -0.02 * s, 0.05 * s), accent)
	_mk_box(_model, Vector3(0.05, 0.22, 0.22) * s, Vector3(0, body.y * 0.6, -0.05 * s), accent)


# --- movement / AI --------------------------------------------------------------

func _snap_up(v: Vector3) -> Vector3:
	var ax := absf(v.x)
	var ay := absf(v.y)
	var az := absf(v.z)
	if ax >= ay and ax >= az:
		return Vector3(signf(v.x), 0, 0)
	elif ay >= az:
		return Vector3(0, signf(v.y), 0)
	return Vector3(0, 0, signf(v.z))


func _align_up(up: Vector3, delta: float) -> void:
	var body_up := global_transform.basis.y
	var dot := clampf(body_up.dot(up), -1.0, 1.0)
	if dot < -0.9999:
		global_transform.basis = Basis(global_transform.basis.x, PI) * global_transform.basis
	elif dot < 0.9999:
		var full := Quaternion(body_up, up)
		var step := Quaternion.IDENTITY.slerp(full, clampf(delta * ALIGN_SPEED, 0.0, 1.0))
		global_transform.basis = Basis(step) * global_transform.basis
	global_transform.basis = global_transform.basis.orthonormalized()


func _physics_process(delta: float) -> void:
	if species.get("kind", "land") == "fish":
		_swim_physics(delta)
	else:
		_land_physics(delta)
	_animate(delta)
	if _attack_cd > 0.0:
		_attack_cd -= delta


func _player_pos():
	if world != null and world.player != null and is_instance_valid(world.player):
		return world.player.global_position
	return null


func _land_physics(delta: float) -> void:
	var g := world.gravity_at(global_position) if world != null else Vector3.DOWN * 9.8
	var up := -_snap_up(g) if g.length() > 0.01 else Vector3.UP
	_align_up(up, delta)

	var speed: float = species.get("speed", 3.0)
	var temperament: String = species.get("temperament", "neutral")
	var wish := Vector3.ZERO
	var moving_speed := speed
	var ppos = _player_pos()
	var handled := false

	if ppos != null:
		var to_player: Vector3 = ppos - global_position
		var dist := to_player.length()
		if temperament == "hostile" and dist < float(species.get("aggro_range", 12.0)):
			wish = to_player - up * to_player.dot(up)
			handled = true
			if dist < ATTACK_RANGE and _attack_cd <= 0.0:
				if world.player.has_method("take_damage"):
					world.player.take_damage(float(species.get("damage", 5.0)))
				_attack_cd = ATTACK_COOLDOWN
		elif temperament == "passive" and dist < float(species.get("flee_range", 10.0)):
			wish = global_position - ppos
			wish = wish - up * wish.dot(up)
			moving_speed = speed * 1.3
			handled = true

	if not handled:
		_wander_timer -= delta
		if _wander_timer <= 0.0 or _wander_dir == Vector3.ZERO:
			_wander_timer = randf_range(WANDER_MIN, WANDER_MAX)
			var ang := randf() * TAU
			var right := Vector3.RIGHT
			if absf(up.dot(right)) > 0.9:
				right = Vector3.FORWARD
			var fwd0 := up.cross(right).normalized()
			var right0 := fwd0.cross(up).normalized()
			_wander_dir = (fwd0 * cos(ang) + right0 * sin(ang))
			if randf() < 0.25:
				_wander_dir = Vector3.ZERO  # idle pause sometimes
		wish = _wander_dir

	if wish.length() > 0.001:
		wish = (wish - up * wish.dot(up)).normalized()
		var fwd := -global_transform.basis.z
		var new_fwd := fwd.slerp(wish, clampf(delta * 6.0, 0.0, 1.0)) if fwd.dot(wish) > -0.98 else wish
		look_at(global_position + new_fwd, up)

	var v_up := velocity.dot(up)
	v_up += -GRAVITY_ACCEL * delta
	if is_on_floor():
		v_up = maxf(v_up, 0.0)
	velocity = wish * moving_speed + up * v_up
	up_direction = up
	move_and_slide()


func _swim_physics(delta: float) -> void:
	var speed: float = species.get("speed", 2.5)
	_wander_timer -= delta
	if _wander_timer <= 0.0 or _wander_dir == Vector3.ZERO:
		_wander_timer = randf_range(WANDER_MIN, WANDER_MAX)
		_wander_dir = Vector3(randf() * 2 - 1, randf() * 2 - 1, randf() * 2 - 1).normalized()
	# steer back toward the planet's center (deeper water) if drifted out of water
	if planet != null:
		var v := planet.world_to_voxel(global_position)
		if planet.get_id(v) != Blocks.WATER:
			_wander_dir = (planet.global_position - global_position).normalized()
	velocity = velocity.lerp(_wander_dir * speed, clampf(delta * 1.5, 0.0, 1.0))
	if velocity.length() > 0.05:
		look_at(global_position + velocity.normalized(), Vector3.UP)
	move_and_slide()


func _animate(delta: float) -> void:
	var top_speed: float = maxf(float(species.get("speed", 3.0)), 0.1)
	var moving: float = clampf(velocity.length() / top_speed, 0.0, 1.0)
	_phase += delta * (4.0 + moving * 6.0)
	for i in _legs.size():
		var sgn := 1.0 if i % 2 == 0 else -1.0
		_legs[i].rotation.x = sin(_phase * sgn + (PI if i >= 2 else 0.0)) * 0.5 * moving
	if _tail_pivot != null:
		var amp := 0.5 if species.get("kind") == "fish" else 0.25
		_tail_pivot.rotation.y = sin(_phase * 0.6) * amp * maxf(moving, 0.3)
	for i in _segments.size():
		var seg: MeshInstance3D = _segments[i]
		seg.position.x = sin(_phase - float(i) * 0.9) * 0.15 * float(species.get("scale", 1.0)) * maxf(moving, 0.2)


## External damage (not yet exposed to the player -- reserved for a future
## combat pass). Returns true if the creature died from this hit.
func take_hit(dmg: float) -> bool:
	_health -= dmg
	if _health <= 0.0:
		queue_free()
		return true
	return false
