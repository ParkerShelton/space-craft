class_name Watcher
extends Creature
## The thing that only moves when you are not looking at it.
##
## Tall, thin and grey, and it never once lets you see it take a step. Every
## frame it works out whether you can actually SEE it -- inside the camera's
## view, and with a clear line from your eye to its body. Anything at all in the
## way counts, which is what makes a tree trunk cover: stand so the trunk is
## between you and it and it is free to move, however squarely you are facing.
##
## Seen, it is a statue, frozen mid-stride in whatever pose it held. Unseen, it
## is fast -- and it does not come in a straight line. It picks its way between
## spots that are hidden from where you are standing, so when you turn back it
## is behind the next tree rather than out in the open. The longer you stare at
## it, the harder it comes the moment you look away.
##
## It comes out at night, near trees, and crumbles at dawn.

const HEIGHT := 2.6
const SPEED := 6.4
const DASH := 9.5            # after you have been staring at it
const STRIKE_RANGE := 2.2
const STRIKE_DAMAGE := 16.0
const STRIKE_CD := 3.5
const HEALTH := 45.0
const GRAV := 20.0
const SIGHT := 60.0          # beyond this it does not care whether you look
const DREAD_RANGE := 14.0    # how close before you start to feel it behind you
const COVER_R := 11.0        # how far out it looks for somewhere to hide

var _body_n: Node3D
var _head: Node3D
var _limb_arms: Array = []
var _limb_legs: Array = []
var _face_mat: StandardMaterial3D
var _up := Vector3.UP
var _vy := 0.0
var _seen := false
var _stare := 0.0            # seconds you have been looking at it
var _step_phase := 0.0
var _goal := Vector3.ZERO
var _goal_t := 0.0
var _cd := 0.0
var _flash := 0.0
var _mats: Array = []
var _die_t := -1.0
var _pale := Color(0.62, 0.62, 0.6)


func setup_watcher(p: Planet, w: WorldManager) -> void:
	planet = p
	world = w
	species = {"name": "Watcher", "kind": "land", "temperament": "hostile",
		"health": HEALTH, "drops": [{"id": Blocks.BONE, "min": 1, "max": 2}]}
	_health = HEALTH
	_build()
	var col := CollisionShape3D.new()
	var cap := CapsuleShape3D.new()
	cap.radius = 0.35
	cap.height = HEIGHT
	col.shape = cap
	col.position = Vector3(0, HEIGHT * 0.5, 0)
	add_child(col)
	_hitbox = col


func _mat(c: Color, glow := 0.0) -> StandardMaterial3D:
	var m := StandardMaterial3D.new()
	m.albedo_color = c
	m.roughness = 0.95
	m.emission_enabled = true
	m.emission = c * glow
	if glow <= 0.0:
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


## Thin, hunched, far too tall, and the same grey all over except the face.
func _build() -> void:
	_body_n = Node3D.new()
	add_child(_body_n)
	var dark := _mat(Color(0.09, 0.09, 0.1))
	# The face glows just enough to be caught out of the corner of an eye at
	# night -- a pale smudge between the trees, and then it is not there.
	_face_mat = _mat(_pale, 0.35)
	_box(_body_n, Vector3(0.5, 1.0, 0.3), Vector3(0, 1.55, 0), dark)      # chest
	_box(_body_n, Vector3(0.42, 0.5, 0.28), Vector3(0, 0.95, 0.04), dark)  # waist
	_head = Node3D.new()
	_head.position = Vector3(0, 2.15, 0)
	_body_n.add_child(_head)
	_box(_head, Vector3(0.34, 0.38, 0.32), Vector3(0, 0.1, 0), dark)
	# A face, and nothing on it. Lit by your torch it is the only pale thing out
	# there; in the dark it is not there at all.
	_box(_head, Vector3(0.26, 0.3, 0.02), Vector3(0, 0.1, -0.17), _face_mat)
	for sx in [-1.0, 1.0]:
		# Arms far too long, hanging past the knee.
		var sh := Node3D.new()
		sh.position = Vector3(sx * 0.3, 1.95, 0)
		_body_n.add_child(sh)
		_box(sh, Vector3(0.13, 0.75, 0.13), Vector3(0, -0.37, 0), dark)
		var el := Node3D.new()
		el.position = Vector3(0, -0.75, 0)
		sh.add_child(el)
		_box(el, Vector3(0.11, 0.8, 0.11), Vector3(0, -0.4, 0), dark)
		for f in 3:
			_box(el, Vector3(0.035, 0.3, 0.035),
				Vector3((f - 1) * 0.045, -0.93, 0), _face_mat)   # long pale fingers
		_limb_arms.append([sh, el])
		var hip := Node3D.new()
		hip.position = Vector3(sx * 0.16, 0.95, 0)
		_body_n.add_child(hip)
		_box(hip, Vector3(0.15, 0.95, 0.15), Vector3(0, -0.47, 0), dark)
		_limb_legs.append(hip)


# --- can you see it? -------------------------------------------------------------

func _player():
	if world != null and world.player != null and is_instance_valid(world.player):
		return world.player
	return null


## True when you could really see it right now: in front of you, inside your
## view, and with nothing between your eye and it. A trunk, a wall, your own
## roof -- anything in the way and it is free to move.
func _is_seen(pl) -> bool:
	if pl == null:
		return false
	var cam = pl.get("_camera")
	if cam == null or not is_instance_valid(cam):
		return false
	var eye: Vector3 = (cam as Camera3D).global_position
	var fwd: Vector3 = -(cam as Camera3D).global_transform.basis.z
	var mid: Vector3 = global_position + _up * (HEIGHT * 0.5)
	if eye.distance_to(mid) > SIGHT:
		return false
	# Generous about what counts as "in view", because being caught moving at
	# the corner of your eye would feel like cheating.
	var to := (mid - eye).normalized()
	if to.dot(fwd) < 0.55:
		return false
	var space := get_world_3d().direct_space_state
	var ex: Array[RID] = [get_rid(), (pl as CollisionObject3D).get_rid()]
	for h in [HEIGHT * 0.9, HEIGHT * 0.5, HEIGHT * 0.15]:
		var q := PhysicsRayQueryParameters3D.create(eye, global_position + _up * h, 1)
		q.exclude = ex
		if space.intersect_ray(q).is_empty():
			return true
	return false


## Whether a spot is hidden from where you are standing.
func _hidden_from(pl, at: Vector3) -> bool:
	var cam = pl.get("_camera")
	if cam == null:
		return true
	var eye: Vector3 = (cam as Camera3D).global_position
	var space := get_world_3d().direct_space_state
	var q := PhysicsRayQueryParameters3D.create(eye, at + _up * (HEIGHT * 0.6), 1)
	q.exclude = [get_rid(), (pl as CollisionObject3D).get_rid()]
	return not space.intersect_ray(q).is_empty()


## Somewhere closer to you that you cannot see -- behind a trunk, a rock, the
## corner of your own house. Falls back to straight at you when there is no
## cover to be had.
func _pick_cover(pl, ppos: Vector3) -> Vector3:
	var best := ppos
	var best_score := -1e9
	var here := global_position
	for i in 10:
		var ang := TAU * float(i) / 10.0 + randf() * 0.3
		var t1 := _up.cross(Vector3.RIGHT if absf(_up.x) < 0.9 else Vector3.FORWARD).normalized()
		var t2 := _up.cross(t1).normalized()
		var r := randf_range(3.0, COVER_R)
		var at := ppos + (t1 * cos(ang) + t2 * sin(ang)) * r
		var g = _ground_at(at)
		if g == null:
			continue
		var spot: Vector3 = g as Vector3
		# Nearer to you is better, hidden is much better, and a spot behind us
		# is worth less than one we are already heading toward.
		var score := -spot.distance_to(ppos) * 1.2 - spot.distance_to(here) * 0.4
		if _hidden_from(pl, spot):
			score += 14.0
		if score > best_score:
			best_score = score
			best = spot
	return best


func _ground_at(at: Vector3):
	var space := get_world_3d().direct_space_state
	var q := PhysicsRayQueryParameters3D.create(at + _up * 6.0, at - _up * 8.0, 1)
	q.exclude = [get_rid()]
	var hit := space.intersect_ray(q)
	if hit.is_empty():
		return null
	return hit["position"]


# --- the frame --------------------------------------------------------------------

func _physics_process(delta: float) -> void:
	if world == null or planet == null:
		return
	var gv := world.gravity_at(global_position)
	_up = -_snap_up(gv) if gv.length() > 0.01 else Vector3.UP
	if _die_t >= 0.0:
		_crumble(delta)
		return
	var pl = _player()
	_seen = _is_seen(pl)
	_cd = maxf(_cd - delta, 0.0)
	if _flash > 0.0:
		_flash = maxf(_flash - delta * 4.0, 0.0)
		for m in _mats:
			(m as StandardMaterial3D).emission = Color(0.8, 0.1, 0.1) * _flash
	# Dawn: it does not flee, it simply stops being there.
	if planet.night_factor() < 0.25 and not daylight_ok:
		_die_t = 0.0
		_dropped = true
		return
	if pl == null:
		return
	var ppos: Vector3 = (pl as Node3D).global_position
	var dist := global_position.distance_to(ppos)
	_tell_player(pl, dist)
	if _seen:
		# A statue. Not a breath, not a turn of the head -- everything it was
		# doing stops exactly where it was.
		_stare += delta
		velocity = Vector3.ZERO
		up_direction = _up
		move_and_slide()
		return
	# Free to move. Staring at it only makes this worse.
	var rush: float = lerpf(SPEED, DASH, clampf(_stare / 4.0, 0.0, 1.0))
	_stare = maxf(_stare - delta * 0.6, 0.0)
	if dist < STRIKE_RANGE and _cd <= 0.0:
		_strike(pl)
	_goal_t -= delta
	if _goal_t <= 0.0 or _goal.distance_to(ppos) > COVER_R * 2.0:
		_goal_t = randf_range(0.6, 1.2)
		# Close in, it stops being careful and simply comes.
		_goal = ppos if dist < 6.0 else _pick_cover(pl, ppos)
	var wish := _goal - global_position
	wish -= _up * wish.dot(_up)
	if wish.length() < 0.6:
		_goal_t = 0.0
	var dir := wish.normalized() if wish.length() > 0.01 else Vector3.ZERO
	_walk(dir, rush, delta)
	_stride(delta, rush)


## Ground movement: it walks, it does not float, and it hops small ledges the
## way the animals do.
func _walk(dir: Vector3, speed: float, delta: float) -> void:
	_vy -= GRAV * delta
	if is_on_floor():
		_vy = maxf(_vy, 0.0)
		if dir != Vector3.ZERO and _step_up_needed(dir, _up):
			_vy = 6.5
	velocity = dir * speed + _up * _vy
	up_direction = _up
	move_and_slide()
	# Always facing you is half of what makes it wrong. It turns while you are
	# not looking, so you only ever see the result.
	var pl = _player()
	if pl != null:
		var to := (pl as Node3D).global_position - global_position
		to -= _up * to.dot(_up)
		if to.length() > 0.01:
			var z := -to.normalized()
			var x := _up.cross(z).normalized()
			global_transform.basis = Basis(x, _up, x.cross(_up).normalized()).orthonormalized()


func _stride(delta: float, speed: float) -> void:
	_step_phase += delta * (2.0 + speed * 0.9)
	var swing := sin(_step_phase) * 0.7
	if _limb_legs.size() >= 2:
		(_limb_legs[0] as Node3D).rotation.x = swing
		(_limb_legs[1] as Node3D).rotation.x = -swing
	# The arms do not swing. They hang, and that is worse.
	for a in _limb_arms:
		((a as Array)[0] as Node3D).rotation.x = -swing * 0.12
	_body_n.rotation.x = 0.12 + sin(_step_phase * 0.5) * 0.02


## Close enough, and you were not looking. One blow, and it is gone again.
func _strike(pl) -> void:
	_cd = STRIKE_CD
	if pl.has_method("take_damage"):
		pl.take_damage(STRIKE_DAMAGE)
	if pl.has_method("notify"):
		pl.notify("Something struck you from behind")
	var away := (pl as Node3D).global_position - global_position
	away -= _up * away.dot(_up)
	if away.length() > 0.01 and "velocity" in pl:
		pl.velocity += away.normalized() * 9.0 + _up * 4.0
	for a in _limb_arms:
		((a as Array)[0] as Node3D).rotation.x = 2.4
	# Straight back into cover rather than standing there to be looked at.
	_goal_t = 0.0
	_stare = 0.0


## The feeling of being followed: the closer it is while you cannot see it, the
## heavier it gets. The player turns this into a dark pulse at the edges of the
## screen -- the only warning you get.
func _tell_player(pl, dist: float) -> void:
	if not pl.has_method("dread"):
		return
	if _seen or dist > DREAD_RANGE:
		return
	pl.dread(clampf(1.0 - dist / DREAD_RANGE, 0.0, 1.0))


## Set on one summoned by hand, so it can be watched in daylight.
var daylight_ok := false


# --- being hit ----------------------------------------------------------------------

func take_hit(dmg: float, _stagger: float = 0.0) -> bool:
	if _die_t >= 0.0:
		return true
	_health -= dmg
	_flash = 1.0
	if _health <= 0.0:
		_grant_drops()
		_die_t = 0.0
		set_collision_layer_value(1, false)
		set_collision_layer_value(CORPSE_LAYER, true)
		return true
	return false


## It folds up where it stands and is not there any more.
func _crumble(delta: float) -> void:
	_die_t += delta
	var k := clampf(_die_t / 0.9, 0.0, 1.0)
	_body_n.scale = Vector3(1.0 + 0.3 * k, maxf(1.0 - k, 0.02), 1.0 + 0.3 * k)
	_body_n.position = Vector3.ZERO
	velocity = -_up * 2.0
	up_direction = _up
	move_and_slide()
	if _die_t > 1.3:
		queue_free()
