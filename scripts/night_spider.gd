class_name NightSpider
extends Creature
## Something that comes out after dark: eight legs, red eyes, and a jump.
##
## Nothing about how it moves is animated by hand. Each leg has a spot on the
## ground it would like its foot to be -- found by casting a ray down from where
## the leg rests, relative to the body -- and the foot stays planted where it
## last landed until the body has carried that spot too far away. Then it steps:
## lifted in a short arc to the new spot, while its neighbours hold still. Legs
## go in two alternating sets, as a real spider's do, so it always has four feet
## down. Each leg is two segments bent by two-bone inverse kinematics from the
## hip to wherever the foot is, with the knee pushed up and out.
##
## The body rides at a fixed height over its feet and tilts to the plane they
## make, so it climbs a step by reaching a foot up onto it first, and sits level
## on a slope. It is a Creature, so swords, bullets and loot treat it like any
## other animal; everything it does in the world is its own.

const LEGS := 8
const UPPER := 1.15          # hip to knee
const LOWER := 1.35          # knee to foot
const RIDE := 0.7            # body height over the ground
const STEP_DIST := 0.75      # how far the ground spot drifts before a foot moves
const STEP_TIME := 0.14
const STEP_LIFT := 0.38
const LEAD := 0.22           # feet land ahead of a moving body by this many seconds
const RAY_UP := 1.8
const RAY_DOWN := 2.6
const MAX_CLIMB := 2.6       # a ledge higher than this turns it back

const SPEED := 4.4
const AGGRO := 30.0
const POUNCE_RANGE := 7.5
const POUNCE_MIN := 2.6
const BITE_RANGE := 1.9
const BITE_DAMAGE := 6.0
const POUNCE_DAMAGE := 9.0
const GRAV := 22.0
const HEALTH := 36.0

const C_BODY := Color(0.10, 0.08, 0.11)
const C_LEG := Color(0.14, 0.11, 0.14)
const C_MARK := Color(0.42, 0.12, 0.40)
const C_EYE := Color(1.0, 0.12, 0.08)

var _hips: Array = []        # body-local
var _rest: Array = []        # body-local resting foot spot
var _foot: Array = []        # world: where each foot is now
var _from: Array = []
var _to: Array = []
var _step: Array = []        # -1 planted, else 0..1 through a step
var _femur: Array = []
var _tibia: Array = []
var _look: Node3D            # the visible body, which lunges and crouches
var _up := Vector3.UP
var _heading := Vector3.FORWARD
var _hvel := Vector3.ZERO
var _air := false
var _vy := 0.0
var _ai := "wander"
var _ai_t := 0.0
var _cd := 0.0
var _hit_done := false
var _crouch := 0.0
var _lunge := 0.0
var _flash := 0.0
var _day_t := 0.0
var _die_t := 0.0
var _blocked_t := 0.0
var _mats: Array = []
var _planted := false
## Set on one summoned by hand, so it can be watched in daylight.
var daylight_ok := false


func setup_spider(p: Planet, w: WorldManager) -> void:
	planet = p
	world = w
	species = {"name": "Night Stalker", "kind": "land", "temperament": "hostile",
		"health": HEALTH,
		"drops": [{"id": Blocks.FIBRE, "min": 2, "max": 4}, {"id": Blocks.BONE, "min": 0, "max": 1}]}
	_health = HEALTH
	_build_spider()
	var col := CollisionShape3D.new()
	var sh := SphereShape3D.new()
	sh.radius = 0.55
	col.shape = sh
	add_child(col)
	_hitbox = col
	_heading = Vector3(randf() - 0.5, 0, randf() - 0.5).normalized()


# --- the body -------------------------------------------------------------------

func _mat(c: Color, glow := 0.0) -> StandardMaterial3D:
	var m := StandardMaterial3D.new()
	m.albedo_color = c
	m.roughness = 0.8
	if glow > 0.0:
		m.emission_enabled = true
		m.emission = c
		m.emission_energy_multiplier = glow
	else:
		# Emission is kept on so a hit can flash it red.
		m.emission_enabled = true
		m.emission = Color(0, 0, 0)
		_mats.append(m)
	return m


func _box(parent: Node3D, size: Vector3, pos: Vector3, m: Material) -> MeshInstance3D:
	var mi := MeshInstance3D.new()
	var bm := BoxMesh.new()
	bm.size = size
	mi.mesh = bm
	mi.material_override = m
	mi.position = pos
	parent.add_child(mi)
	return mi


func _build_spider() -> void:
	_look = Node3D.new()
	add_child(_look)
	var body := _mat(C_BODY)
	var mark := _mat(C_MARK)
	var eye := _mat(C_EYE, 3.0)
	# Front (-Z) the head and jaws, behind it the big abdomen.
	_box(_look, Vector3(0.72, 0.42, 0.72), Vector3(0, 0.02, -0.28), body)
	_box(_look, Vector3(0.95, 0.72, 1.05), Vector3(0, 0.18, 0.6), body)
	_box(_look, Vector3(0.6, 0.1, 0.7), Vector3(0, 0.55, 0.62), mark)
	_box(_look, Vector3(0.12, 0.3, 0.5), Vector3(0, 0.5, 0.62), mark)
	for sx in [-1.0, 1.0]:
		_box(_look, Vector3(0.09, 0.09, 0.03), Vector3(sx * 0.12, 0.12, -0.65), eye)
		_box(_look, Vector3(0.06, 0.06, 0.03), Vector3(sx * 0.26, 0.16, -0.62), eye)
		_box(_look, Vector3(0.05, 0.05, 0.03), Vector3(sx * 0.07, 0.2, -0.65), eye)
		_box(_look, Vector3(0.07, 0.2, 0.07), Vector3(sx * 0.1, -0.2, -0.62), mark)
	var leg := _mat(C_LEG)
	for i in LEGS:
		var side := -1.0 if i < 4 else 1.0
		var k := i % 4
		var z: float = [-0.52, -0.26, -0.02, 0.22][k]
		_hips.append(Vector3(side * 0.34, 0.0, z))
		# Front pair reaches forward, back pair back, the middle two out.
		var rz: float = [-1.35, -0.5, 0.35, 1.15][k]
		var rx: float = [1.25, 1.55, 1.55, 1.3][k]
		_rest.append(Vector3(side * rx, -RIDE, rz))
		_foot.append(Vector3.ZERO)
		_from.append(Vector3.ZERO)
		_to.append(Vector3.ZERO)
		_step.append(-1.0)
		for arr in [_femur, _tibia]:
			var mi := MeshInstance3D.new()
			var bm := BoxMesh.new()
			bm.size = Vector3(0.1, 0.1, 1.0) if arr == _femur else Vector3(0.07, 0.07, 1.0)
			mi.mesh = bm
			mi.material_override = leg
			# Placed in world space every frame by the IK, not carried by the body.
			mi.top_level = true
			add_child(mi)
			arr.append(mi)


# --- where things are -------------------------------------------------------------

func _space() -> PhysicsDirectSpaceState3D:
	return get_world_3d().direct_space_state


## The ground under a point, along the local down. null if there is none in reach.
func _ground(p: Vector3, up_len := RAY_UP, down_len := RAY_DOWN):
	var q := PhysicsRayQueryParameters3D.create(p + _up * up_len, p - _up * down_len, 1)
	var ex: Array[RID] = [get_rid()]
	if world != null and world.player != null and is_instance_valid(world.player):
		ex.append((world.player as CollisionObject3D).get_rid())
	q.exclude = ex
	var hit := _space().intersect_ray(q)
	if hit.is_empty():
		return null
	return hit["position"]


func _foot_target(i: int) -> Vector3:
	var lead := _hvel * LEAD
	var want: Vector3 = global_transform * (_rest[i] as Vector3) + lead
	# Threat pose: the front pair lifted and reaching while it squares up or bites.
	if i % 4 == 0 and (_ai == "crouch" or _ai == "bite"):
		return global_transform * ((_rest[i] as Vector3) * Vector3(0.7, 0, 0.8) + Vector3(0, 0.55, -0.1))
	var g = _ground(want)
	return g if g != null else want


# --- the frame ----------------------------------------------------------------------

func _physics_process(delta: float) -> void:
	if world == null or planet == null:
		return
	var gv := world.gravity_at(global_position)
	_up = -_snap_up(gv) if gv.length() > 0.01 else Vector3.UP
	if not _planted:
		_planted = true
		for i in LEGS:
			_foot[i] = _foot_target(i)
	if _ai == "dead":
		_die(delta)
		return
	_think(delta)
	_move(delta)
	_orient(delta)
	_step_legs(delta)
	_pose(delta)


func _player():
	if world != null and world.player != null and is_instance_valid(world.player):
		return world.player
	return null


func _flat(v: Vector3) -> Vector3:
	return v - _up * v.dot(_up)


## What it wants to do, and which way.
func _think(delta: float) -> void:
	_cd = maxf(_cd - delta, 0.0)
	_ai_t -= delta
	var pl = _player()
	var to_p := Vector3.ZERO
	var dist := INF
	if pl != null:
		to_p = _flat((pl as Node3D).global_position - global_position)
		dist = ((pl as Node3D).global_position - global_position).length()
	# Daylight drives it off: it backs away from you and is gone within seconds.
	if planet.night_factor() < 0.25 and _ai != "pounce" and not daylight_ok:
		_ai = "leave"
	match _ai:
		"wander":
			if _ai_t <= 0.0:
				_ai_t = randf_range(2.5, 5.0)
				var ang := randf_range(-1.6, 1.6)
				_heading = _heading.rotated(_up, ang).normalized()
			_wish(_heading, SPEED * 0.35, delta)
			if dist < AGGRO:
				_ai = "stalk"
		"stalk":
			if dist > AGGRO * 1.5:
				_ai = "wander"
			elif dist < BITE_RANGE and _cd <= 0.0:
				_ai = "bite"
				_ai_t = 0.4
				_hit_done = false
			elif dist < POUNCE_RANGE and dist > POUNCE_MIN and _cd <= 0.0 and randf() < delta * 1.5:
				_ai = "crouch"
				_ai_t = 0.5
			# Closing in, with a little weave so it does not come in a straight line.
			var weave := sin(Time.get_ticks_msec() * 0.0021 + get_instance_id()) * 0.45
			var d := to_p.normalized().rotated(_up, weave) if to_p.length() > 0.01 else _heading
			_wish(d, SPEED, delta)
		"crouch":
			_face(to_p, delta * 10.0)
			_wish(Vector3.ZERO, 0.0, delta)
			if _ai_t <= 0.0:
				_pounce(pl)
		"pounce":
			if not _hit_done and pl != null and dist < 1.7:
				_hit_done = true
				_hurt_player(pl, POUNCE_DAMAGE)
			if not _air:
				_ai = "retreat"
				_ai_t = 0.9
				_cd = 1.8
		"bite":
			_face(to_p, delta * 12.0)
			_wish(Vector3.ZERO, 0.0, delta)
			if not _hit_done and _ai_t < 0.2:
				_hit_done = true
				if pl != null and dist < BITE_RANGE + 0.4:
					_hurt_player(pl, BITE_DAMAGE)
			if _ai_t <= 0.0:
				_ai = "retreat"
				_ai_t = 0.6
				_cd = 1.3
		"retreat":
			_wish(-to_p.normalized() if to_p.length() > 0.01 else -_heading, SPEED * 0.7, delta)
			if to_p.length() > 0.01:
				_face(to_p, delta * 4.0)
			if _ai_t <= 0.0:
				_ai = "stalk"
		"leave":
			_day_t += delta
			_wish(-to_p.normalized() if to_p.length() > 0.01 else _heading, SPEED * 0.8, delta)
			if _day_t > 6.0 or dist > 60.0:
				_ai = "dead"
				_die_t = 0.0
				_dropped = true   # left, not killed: nothing to take


func _wish(dir: Vector3, speed: float, delta: float) -> void:
	var d := _flat(dir)
	var want := d.normalized() * speed if d.length() > 0.001 else Vector3.ZERO
	_hvel = _hvel.lerp(want, clampf(delta * 6.0, 0.0, 1.0))
	if want.length() > 0.1 and _ai != "retreat":
		_face(want, delta * 5.0)


func _face(dir: Vector3, t: float) -> void:
	var d := _flat(dir)
	if d.length() < 0.001:
		return
	_heading = _flat(_heading).normalized().slerp(d.normalized(), clampf(t, 0.0, 1.0)).normalized()


func _pounce(pl) -> void:
	_ai = "pounce"
	_hit_done = false
	_air = true
	var to_p := Vector3.ZERO
	var rise := 0.0
	if pl != null:
		var rel: Vector3 = (pl as Node3D).global_position - global_position
		to_p = _flat(rel)
		rise = rel.dot(_up)
	var flat_d := to_p.length()
	# Timed so it arrives: a flight a little under a second, faster over more ground.
	var t := clampf(flat_d / 9.0, 0.35, 0.8)
	_hvel = to_p / t if flat_d > 0.01 else _heading * 6.0
	_vy = (rise + 0.5 * GRAV * t * t) / t
	_vy = clampf(_vy, 4.0, 11.0)


func _hurt_player(pl, dmg: float) -> void:
	if pl.has_method("take_damage"):
		pl.take_damage(dmg)
	# A shove away, so a hit is felt rather than just read off the health bar.
	var away := _flat((pl as Node3D).global_position - global_position)
	if away.length() > 0.01 and "velocity" in pl:
		pl.velocity += away.normalized() * 6.0 + _up * 3.0


## Across the ground, and up and down over it.
func _move(delta: float) -> void:
	var v := _hvel
	if _air:
		_vy -= GRAV * delta
		v += _up * _vy
	velocity = v
	up_direction = _up
	move_and_slide()
	if _air:
		var g = _ground(global_position, 0.2, RIDE + 0.05)
		if _vy < 0.0 and g != null:
			_air = false
			_vy = 0.0
			global_position = (g as Vector3) + _up * RIDE
			for i in LEGS:
				_step[i] = -1.0
				_foot[i] = _foot_target(i)
		return
	# The height to ride at: over the ground beneath it, over the feet, and over
	# whatever is just ahead -- the last is what lifts it up a step before it
	# walks into the face of it.
	var h := global_position.dot(_up)
	var target := -INF
	var under = _ground(global_position)
	if under != null:
		target = (under as Vector3).dot(_up)
	var ahead_dir := _flat(_hvel).normalized() if _hvel.length() > 0.2 else Vector3.ZERO
	if ahead_dir != Vector3.ZERO:
		var ahead = _ground(global_position + ahead_dir * 0.95, MAX_CLIMB, RAY_DOWN)
		if ahead != null:
			var ah := (ahead as Vector3).dot(_up)
			if ah - h < MAX_CLIMB - RIDE:
				target = maxf(target, ah)
	var fsum := 0.0
	for i in LEGS:
		fsum += (_foot[i] as Vector3).dot(_up)
	target = maxf(target, fsum / LEGS) if target > -INF else fsum / LEGS
	if under == null and h - target > 1.2:
		_air = true    # walked off an edge
		_vy = 0.0
		return
	var goal := target + RIDE
	global_position += _up * (lerpf(h, goal, clampf(delta * 9.0, 0.0, 1.0)) - h)
	# Pushing into a wall it cannot climb: turn and go round.
	if is_on_wall() and _hvel.length() > 0.5:
		_blocked_t += delta
		if _blocked_t > 0.6:
			_blocked_t = 0.0
			_heading = _heading.rotated(_up, (1.0 if randf() < 0.5 else -1.0) * randf_range(1.2, 2.2))
			if _ai == "wander":
				_ai_t = 2.0
	else:
		_blocked_t = 0.0


## Face the heading, tilted to the plane its feet make.
func _orient(delta: float) -> void:
	var n := _up
	if not _air:
		var front := Vector3.ZERO
		var back := Vector3.ZERO
		var left := Vector3.ZERO
		var right := Vector3.ZERO
		for i in LEGS:
			var f: Vector3 = _foot[i]
			if i % 4 < 2: front += f
			else: back += f
			if i < 4: left += f
			else: right += f
		var fwd := front - back
		var side := right - left
		var fit := side.cross(fwd)
		if fit.length() > 0.01:
			fit = fit.normalized()
			if fit.dot(_up) < 0.0:
				fit = -fit
			n = _up.lerp(fit, 0.6).normalized()
	var cur_up := global_transform.basis.y
	var y := cur_up.slerp(n, clampf(delta * 8.0, 0.0, 1.0)).normalized()
	var z := -(_heading - y * _heading.dot(y))
	if z.length() < 0.01:
		z = global_transform.basis.z
	z = z.normalized()
	var x := y.cross(z).normalized()
	global_transform.basis = Basis(x, y, x.cross(y).normalized())


## Plant, step, and bend every leg.
func _step_legs(delta: float) -> void:
	var stepping := [false, false]
	for i in LEGS:
		if float(_step[i]) >= 0.0:
			stepping[_group(i)] = true
	var still := _hvel.length() < 0.3
	for i in LEGS:
		if _air:
			# Legs drawn in and reaching forward while it flies.
			var r: Vector3 = _rest[i]
			_foot[i] = global_transform * (r * Vector3(0.75, 0.35, 0.8) + Vector3(0, 0.1, -0.35))
			continue
		var tgt := _foot_target(i)
		var s := float(_step[i])
		if s >= 0.0:
			s += delta / STEP_TIME
			_to[i] = tgt      # keep aiming at the spot as the body moves on
			if s >= 1.0:
				_step[i] = -1.0
				_foot[i] = _to[i]
			else:
				_step[i] = s
				var a: Vector3 = _from[i]
				var b: Vector3 = _to[i]
				_foot[i] = a.lerp(b, s) + _up * sin(s * PI) * STEP_LIFT
			continue
		var drift := (_foot[i] as Vector3).distance_to(tgt)
		var need := drift > STEP_DIST or (still and drift > 0.3) or drift > STEP_DIST * 2.2
		# A leg lifts only while the other set is all down, so four feet always are.
		if need and not stepping[1 - _group(i)]:
			_step[i] = 0.0
			_from[i] = _foot[i]
			_to[i] = tgt
			stepping[_group(i)] = true


## The two alternating sets: front-left, second-right, third-left, back-right --
## and the rest.
func _group(i: int) -> int:
	return ((i % 4) + (1 if i >= 4 else 0)) % 2


## Two-bone IK: hip to foot, knee up and out.
func _pose(delta: float) -> void:
	_crouch = move_toward(_crouch, 1.0 if _ai == "crouch" else 0.0, delta * 4.0)
	var lunge_want := 0.0
	if _ai == "bite":
		lunge_want = sin(clampf(1.0 - _ai_t / 0.4, 0.0, 1.0) * PI)
	_lunge = move_toward(_lunge, lunge_want, delta * 8.0)
	_look.position = Vector3(0, -0.28 * _crouch, -0.35 * _lunge)
	_look.rotation = Vector3(0.18 * _crouch - 0.15 * _lunge, 0, 0)
	if _flash > 0.0:
		_flash = maxf(_flash - delta * 4.0, 0.0)
		for m in _mats:
			(m as StandardMaterial3D).emission = Color(0.9, 0.1, 0.05) * _flash
	var body_up := global_transform.basis.y
	for i in LEGS:
		var hip: Vector3 = _look.global_transform * (_hips[i] as Vector3)
		var f: Vector3 = _foot[i]
		var to_f := f - hip
		var d := to_f.length()
		var dir := to_f / maxf(d, 0.0001)
		d = clampf(d, 0.15, UPPER + LOWER - 0.02)
		var ca := clampf((UPPER * UPPER + d * d - LOWER * LOWER) / (2.0 * UPPER * d), -1.0, 1.0)
		var sa := sqrt(1.0 - ca * ca)
		var outward := hip - global_position
		outward = (outward - body_up * outward.dot(body_up)).normalized()
		var pole := body_up + outward * 0.25
		var bend := pole - dir * pole.dot(dir)
		if bend.length() < 0.001:
			bend = body_up
		bend = bend.normalized()
		var knee := hip + dir * UPPER * ca + bend * UPPER * sa
		_segment(_femur[i], hip, knee, body_up)
		_segment(_tibia[i], knee, hip + dir * d, body_up)


func _segment(mi: MeshInstance3D, a: Vector3, b: Vector3, up_hint: Vector3) -> void:
	var z := b - a
	var l := z.length()
	if l < 0.001:
		return
	z /= l
	var x := up_hint.cross(z)
	if x.length() < 0.01:
		x = z.cross(Vector3.RIGHT if absf(z.x) < 0.9 else Vector3.FORWARD)
	x = x.normalized()
	var y := z.cross(x).normalized()
	mi.global_transform = Transform3D(Basis(x, y, z * l), (a + b) * 0.5)


# --- being hit -----------------------------------------------------------------------

func take_hit(dmg: float, _stagger: float = 0.0) -> bool:
	if _ai == "dead":
		return true
	_health -= dmg
	_flash = 1.0
	if _health <= 0.0:
		_grant_drops()
		_ai = "dead"
		_die_t = 0.0
		set_collision_layer_value(1, false)
		set_collision_layer_value(CORPSE_LAYER, true)
		return true
	# A hit knocks it off whatever it was doing and back a step.
	if _ai != "pounce":
		_ai = "retreat"
		_ai_t = 0.45
		_cd = maxf(_cd, 0.6)
	return false


## Legs curl in under it, it drops, and it is gone.
func _die(delta: float) -> void:
	_die_t += delta
	var k := clampf(_die_t / 0.7, 0.0, 1.0)
	for i in LEGS:
		var r: Vector3 = _rest[i]
		_foot[i] = global_transform * r.lerp(Vector3(r.x * 0.2, -RIDE * 0.4, r.z * 0.2), k)
	_look.position = Vector3(0, -0.45 * k, 0)
	_pose(delta)
	if _die_t > 1.6:
		var s := clampf(1.0 - (_die_t - 1.6) / 0.6, 0.0, 1.0)
		scale = Vector3.ONE * maxf(s, 0.01)
		if s <= 0.0:
			queue_free()
