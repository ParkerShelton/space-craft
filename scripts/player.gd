class_name Player
extends CharacterBody3D

## Hybrid controller.
##
## GROUND mode (gravity strong): the body smoothly stands up so its "up" points
## away from the planet center; you walk on the tangent plane, jump, and can hold
## jump to jetpack. Climb high enough that gravity fades and you...
## FLOAT mode (gravity weak / deep space): full 6-axis flight, no forced
## orientation -- WASD moves along your view, jump/crouch thrust up/down.
##
## The switch is purely a function of local gravity magnitude, so weak planets let
## you float even near the surface and strong ones "capture" you into walking.

const WALK_SPEED := 7.0
const JUMP_SPEED := 8.0
const JETPACK_ACCEL := 9.0        # gentle thrust
const JETPACK_MAX_SPEED := 8.0    # cap so it can't launch you off
const FLY_SPEED := 16.0
const FLY_ACCEL := 6.0
const FLY_DAMP := 3.0
const MOUSE_SENS := 0.0025
const ALIGN_SPEED := 2.5          # how fast we stand upright when captured (lower = smoother)
const FLIGHT_THRESHOLD := 3.0     # gravity (m/s^2) below which we float
const REACH := 6.0                # block interaction distance

var world: WorldManager           # set by main.gd
var grounded := false

# --- inventory (slots; you can only place what you have) ---
const SLOTS := 32
const HOTBAR_SLOTS := 8
const STACK_MAX := 99
var inv: Array = []               # each slot: {"id": int, "count": int}
var active_slot := 0              # which slot we place from
var inv_open := false
# mining (hold left-click to break; harder blocks take longer)
var _mine_key := ""               # identifies the block currently being mined
var _mine_time := 0.0             # seconds spent mining the current block
var _mine_total := 1.0            # hardness of the current block
var _look_name := ""              # name/use of the block under the crosshair (HUD)
var piloting: Ship = null         # non-null while flying a ship
var aboard: Ship = null           # non-null while walking inside a ship in space
var eva := false                  # floating outside on a tether
var _eva_ship: Ship = null        # ship we're tethered to
var _eva_anchor_local := Vector3.ZERO  # tether attach point in ship-local space
var _tether: MeshInstance3D
var _iv_y := 0.0                  # interior vertical velocity (ship-local)
var _interior_floor := false
var _body_shape: CollisionShape3D
var _home_parent: Node            # where the player lives when not parented to a ship
const ARTIFICIAL_G := 9.0         # interior gravity toward the ship floor
const TETHER_LEN := 18.0          # max EVA tether distance

var _camera: Camera3D
var _ray: RayCast3D
var _pitch := 0.0
var _look := Vector2.ZERO          # accumulated mouse delta, consumed in physics

# UI
var _ui_layer: CanvasLayer
var _crosshair: Label
var _hotbar_label: Label
var _mode_label: Label
var _ship_label: Label
var _target_label: Label
var _toast_label: Label            # transient "Saved"/"Loaded" confirmation
var _toast_time := 0.0
var _inv_panel: Control            # full inventory overlay (toggled with E)
var _hotbar_cells: Array = []      # always-visible hotbar slot views
var _grid_cells: Array = []        # full-inventory slot buttons
var _markers: Array[Label] = []   # one navigation marker per planet


func _ready() -> void:
	# collision capsule
	_body_shape = CollisionShape3D.new()
	var cap := CapsuleShape3D.new()
	cap.radius = 0.4
	cap.height = 1.8
	_body_shape.shape = cap
	add_child(_body_shape)

	_camera = Camera3D.new()
	_camera.position = Vector3(0, 0.7, 0)  # eye height above body center
	_camera.far = 14000.0
	add_child(_camera)

	_ray = RayCast3D.new()
	_ray.target_position = Vector3(0, 0, -REACH)
	_ray.collide_with_bodies = true
	_camera.add_child(_ray)

	# With axis-snapped gravity the ground is always flat, so keep the character
	# glued to it and don't let it slide.
	floor_max_angle = deg_to_rad(50)
	floor_stop_on_slope = true
	floor_snap_length = 0.5
	floor_constant_speed = true
	_home_parent = get_parent()
	Input.mouse_mode = Input.MOUSE_MODE_CAPTURED
	_init_inventory()
	_build_ui()
	_refresh_slots()


# --- inventory ---------------------------------------------------------------

func _init_inventory() -> void:
	inv.clear()
	for i in SLOTS:
		inv.append({"id": Blocks.AIR, "count": 0})
	# starting kit so you can build a ship and terraform right away
	_add_item(Blocks.COCKPIT, 2)
	_add_item(Blocks.THRUSTER, 8)
	_add_item(Blocks.METAL, 64)
	_add_item(Blocks.GRASS, 64)
	_add_item(Blocks.DIRT, 64)
	_add_item(Blocks.ROCK, 64)
	_add_item(Blocks.WOOD, 32)
	_add_item(Blocks.LEAF_0, 32)


# Add n of a block; fills existing stacks first, then empty slots. Returns leftover.
func _add_item(id: int, n: int) -> int:
	if id == Blocks.AIR or n <= 0:
		return n
	for s in inv:
		if s["id"] == id and s["count"] < STACK_MAX:
			var add: int = mini(n, STACK_MAX - s["count"])
			s["count"] += add
			n -= add
			if n <= 0:
				return 0
	for s in inv:
		if s["count"] == 0:
			s["id"] = id
			var add: int = mini(n, STACK_MAX)
			s["count"] = add
			n -= add
			if n <= 0:
				return 0
	return n  # inventory full; leftover dropped


func _selected_id() -> int:
	return inv[active_slot]["id"] if inv[active_slot]["count"] > 0 else Blocks.AIR


func _consume_active() -> void:
	var s = inv[active_slot]
	if s["count"] > 0:
		s["count"] -= 1
		if s["count"] == 0:
			s["id"] = Blocks.AIR
	_refresh_slots()


func _unhandled_input(event: InputEvent) -> void:
	if event is InputEventMouseMotion and Input.mouse_mode == Input.MOUSE_MODE_CAPTURED:
		_look += event.relative
	elif event is InputEventMouseButton and event.pressed:
		if inv_open:
			return  # inventory open: clicks go to the UI
		if Input.mouse_mode != Input.MOUSE_MODE_CAPTURED:
			Input.mouse_mode = Input.MOUSE_MODE_CAPTURED
			return
		if piloting:
			return  # no building while flying
		if event.button_index == MOUSE_BUTTON_RIGHT:
			_edit_block(false)  # placing is instant; breaking is hold-to-mine
		elif event.button_index == MOUSE_BUTTON_WHEEL_UP:
			_cycle_slot(-1)
		elif event.button_index == MOUSE_BUTTON_WHEEL_DOWN:
			_cycle_slot(1)
	elif event is InputEventKey and event.pressed and not event.echo:
		if event.keycode == KEY_ESCAPE:
			if inv_open:
				_toggle_inventory()
			else:
				Input.mouse_mode = Input.MOUSE_MODE_VISIBLE
		elif event.keycode == KEY_F5:
			if world != null and world.save_game():
				_toast("Saved")
			else:
				_toast("Save failed")
		elif event.keycode == KEY_F9:
			# Reload only while on foot -- avoids tearing down ship/pilot state.
			if piloting != null or aboard != null or eva:
				_toast("Can't load while flying")
			elif world != null and world.has_save():
				world.load_game()
				_toast("Loaded")
			else:
				_toast("No save found")
		elif event.keycode == KEY_E:
			_toggle_inventory()
		elif event.keycode == KEY_F:
			_toggle_pilot()
		elif event.keycode == KEY_T:
			_toggle_eva()
		elif piloting:
			return  # while flying, only F/Esc/mouse-look do anything
		elif event.keycode == KEY_G:
			if aboard == null and not eva:
				_start_ship()
		elif event.keycode >= KEY_1 and event.keycode <= KEY_8:
			active_slot = event.keycode - KEY_1
			_refresh_slots()


func _cycle_slot(dir: int) -> void:
	active_slot = (active_slot + dir + HOTBAR_SLOTS) % HOTBAR_SLOTS
	_refresh_slots()


func _toggle_inventory() -> void:
	inv_open = not inv_open
	if _inv_panel != null:
		_inv_panel.visible = inv_open
	Input.mouse_mode = Input.MOUSE_MODE_VISIBLE if inv_open else Input.MOUSE_MODE_CAPTURED
	_refresh_slots()


func _physics_process(delta: float) -> void:
	if _toast_time > 0.0:
		_toast_time -= delta
		if _toast_time <= 0.0 and _toast_label != null:
			_toast_label.visible = false
	if eva:
		_eva_physics(delta)
		_process_mining(delta)
		_update_ui()
		return
	if piloting != null:
		_pilot_physics(delta)
		_update_ui()
		return
	if aboard != null:
		if not is_instance_valid(aboard):
			aboard = null
		else:
			# Walk the interior in the ship's local frame (decoupled from how the
			# ship moves through space -- rock solid at any speed/orientation).
			grounded = true
			_walk_interior(delta, aboard)
			_process_mining(delta)
			_update_ui()
			return
	var g := world.gravity_at(global_position) if world else Vector3(0, -9.8, 0)
	var up := -g.normalized() if g.length() > 0.01 else Vector3.UP
	if _in_water(global_position + up * 0.5) or _in_water(global_position - up * 0.8):
		_swim(delta, up)
	else:
		grounded = g.length() > FLIGHT_THRESHOLD
		if grounded:
			_walk(delta, -_snap_to_axis(g), g.length())
		else:
			_process_float(delta)
	_process_mining(delta)
	_update_ui()


# --- piloting -----------------------------------------------------------------

func _pilot_physics(delta: float) -> void:
	if not is_instance_valid(piloting):
		_exit_pilot()
		return
	var ascend := 0.0
	if Input.is_physical_key_pressed(KEY_SPACE): ascend += 1.0
	if Input.is_physical_key_pressed(KEY_SHIFT): ascend -= 1.0
	var roll := 0.0
	if Input.is_physical_key_pressed(KEY_Q): roll += 1.0
	if Input.is_physical_key_pressed(KEY_E): roll -= 1.0
	piloting.fly(delta, world, {
		"move": _move_input(),
		"ascend": ascend,
		"roll": roll,
		"look": _look,
	})
	_look = Vector2.ZERO
	# ride along so we exit next to the ship and HUD/gravity queries stay local
	global_position = piloting.global_position


func _toggle_pilot() -> void:
	if piloting != null:
		_exit_pilot()
		return
	if world == null:
		return
	var ship := aboard if aboard != null else world.nearest_ship(global_position)
	if ship == null:
		return
	var cockpit_world := ship.to_global(ship.cockpit_local() + Vector3(0.5, 0.5, 0.5))
	if global_position.distance_to(cockpit_world) > 4.0:
		return
	if not ship.get_status()["can_fly"]:
		return
	_enter_pilot(ship)


func _enter_pilot(ship: Ship) -> void:
	if aboard != null:
		_unboard()
	piloting = ship
	ship.flying = true
	ship.velocity = Vector3.ZERO
	velocity = Vector3.ZERO
	_body_shape.disabled = true
	ship.enable_chase_camera()


func _exit_pilot() -> void:
	var ship := piloting
	piloting = null
	_body_shape.disabled = false
	_camera.make_current()
	velocity = Vector3.ZERO
	if not is_instance_valid(ship):
		return
	ship.flying = false
	ship.hide_landing_reticle()

	var g := world.gravity_at(ship.global_position) if world else Vector3.DOWN
	if g.length() < FLIGHT_THRESHOLD:
		# In space: keep the ship's momentum (it coasts) and board it to walk around.
		_board(ship)
	else:
		# On/near a planet: park the ship and stand on it; planet gravity holds you.
		ship.velocity = Vector3.ZERO
		global_position = ship.global_position + ship.global_transform.basis * (ship.center_local() + Vector3(0, 2.0, 0))
		if g.length() > 0.01:
			look_at(global_position - global_transform.basis.z, -g.normalized())


# --- walking inside a ship (aboard) -------------------------------------------

func _board(ship: Ship) -> void:
	aboard = ship
	reparent(ship, true)          # child of the ship: local position rides along automatically
	rotation = Vector3.ZERO       # align to ship axes: up = ship up, facing ship forward
	var stand := _find_interior_stand(ship, ship.cockpit_local())
	position = Vector3(stand) + Vector3(0.5, 1.0, 0.5)  # inside the ship, on the floor
	_pitch = 0.0
	_iv_y = 0.0
	velocity = Vector3.ZERO
	_body_shape.disabled = true   # interior movement is manual, not physics-swept


func _unboard() -> void:
	if aboard != null and get_parent() == aboard:
		reparent(_home_parent, true)
	aboard = null
	_body_shape.disabled = false
	velocity = Vector3.ZERO


# --- EVA (float outside on a tether) ------------------------------------------

func _toggle_eva() -> void:
	if eva:
		var ship := _eva_ship
		_end_eva()
		if is_instance_valid(ship):
			_board(ship)  # climb back inside
	elif aboard != null:
		_begin_eva()


func _begin_eva() -> void:
	var ship := aboard
	_eva_ship = ship
	_eva_anchor_local = ship.cockpit_local() + Vector3(0.5, 0.5, 0.5)  # tether roots at the cockpit
	aboard = null
	reparent(_home_parent, true)
	eva = true
	_body_shape.disabled = false
	# emerge just above the ship, out in open space
	global_position = ship.to_global(_eva_anchor_local + Vector3(0, 3.0, 0))
	velocity = Vector3.ZERO
	_ensure_tether()


func _end_eva() -> void:
	eva = false
	_eva_ship = null
	if _tether != null:
		_tether.visible = false


func _eva_physics(delta: float) -> void:
	if not is_instance_valid(_eva_ship):
		_end_eva()
		return
	_process_float(delta)  # full 6-axis flight, same as deep-space player movement
	# tether constraint: can't drift past TETHER_LEN from the (moving) anchor
	var anchor := _eva_ship.to_global(_eva_anchor_local)
	var vec := global_position - anchor
	var d := vec.length()
	if d > TETHER_LEN:
		var dir := vec / d
		global_position = anchor + dir * TETHER_LEN
		var outward := velocity.dot(dir)
		if outward > 0.0:
			velocity -= dir * outward
	_update_tether(anchor)


func _ensure_tether() -> void:
	if _tether == null:
		_tether = MeshInstance3D.new()
		_tether.mesh = ImmediateMesh.new()
		var mat := StandardMaterial3D.new()
		mat.shading_mode = BaseMaterial3D.SHADING_MODE_UNSHADED
		mat.albedo_color = Color(1.0, 0.85, 0.3)
		_tether.material_override = mat
		_home_parent.add_child(_tether)
	_tether.visible = true


func _update_tether(anchor: Vector3) -> void:
	var m := _tether.mesh as ImmediateMesh
	m.clear_surfaces()
	m.surface_begin(Mesh.PRIMITIVE_LINES)
	m.surface_add_vertex(anchor)
	m.surface_add_vertex(global_position)
	m.surface_end()


# Find a standable interior cell near the cockpit: an air cell with headroom and a
# solid floor directly below. Falls back to just above the cockpit (flat builds).
func _find_interior_stand(ship: Ship, cockpit: Vector3) -> Vector3i:
	var cc := Vector3i(roundi(cockpit.x), roundi(cockpit.y), roundi(cockpit.z))
	var best := cc + Vector3i(0, 1, 0)  # fallback: on top of the cockpit
	var best_d := 1.0e9
	for dx in range(-3, 4):
		for dy in range(-1, 3):
			for dz in range(-3, 4):
				var c := cc + Vector3i(dx, dy, dz)
				if _is_standable(ship, c):
					var d := Vector2(dx, dz).length() + absf(dy) * 0.5
					if d < best_d:
						best_d = d
						best = c
	return best


func _is_standable(ship: Ship, c: Vector3i) -> bool:
	return (not ship.blocks.has(c)) \
		and (not ship.blocks.has(c + Vector3i(0, 1, 0))) \
		and ship.blocks.has(c + Vector3i(0, -1, 0))


## Manual voxel character controller in the ship's local frame.
func _walk_interior(delta: float, ship: Ship) -> void:
	rotation.y -= _look.x * MOUSE_SENS       # yaw around the ship's up
	_pitch = clampf(_pitch - _look.y * MOUSE_SENS, -1.45, 1.45)
	_camera.rotation.x = _pitch
	_look = Vector2.ZERO

	var input := _move_input()
	var yaw := rotation.y
	var fwd := Vector3(-sin(yaw), 0.0, -cos(yaw))
	var right := Vector3(cos(yaw), 0.0, -sin(yaw))
	var wish := right * input.x + fwd * input.y
	if wish.length() > 0.001:
		wish = wish.normalized()
	var disp := wish * WALK_SPEED * delta

	if _interior_floor and Input.is_physical_key_pressed(KEY_SPACE):
		_iv_y = JUMP_SPEED
	_iv_y -= ARTIFICIAL_G * delta

	var pos := position
	# horizontal, per-axis so you slide along walls
	var tx := pos
	tx.x += disp.x
	if not _interior_blocked(ship, tx):
		pos.x = tx.x
	var tz := pos
	tz.z += disp.z
	if not _interior_blocked(ship, tz):
		pos.z = tz.z
	# vertical + floor
	pos.y += _iv_y * delta
	var ft := _interior_floor_top(ship, pos)
	_interior_floor = false
	if pos.y - 0.9 <= ft:
		pos.y = ft + 0.9
		if _iv_y < 0.0:
			_iv_y = 0.0
		_interior_floor = true
	position = pos

	# safety: if you walked off an open edge and fell away, snap back to the cockpit
	if position.y < -60.0:
		position = ship.cockpit_local() + Vector3(0.5, 2.0, 0.5)
		_iv_y = 0.0


# Highest solid block top at or below the player's feet (ship-local Y).
func _interior_floor_top(ship: Ship, pos: Vector3) -> float:
	var cx := floori(pos.x)
	var cz := floori(pos.z)
	var start := floori(pos.y - 0.9 + 0.02)
	for y in range(start, start - 128, -1):
		if ship.blocks.has(Vector3i(cx, y, cz)):
			return float(y + 1)
	return -1.0e9


# Is a wall block occupying the player's body column at this local position?
func _interior_blocked(ship: Ship, pos: Vector3) -> bool:
	var cx := floori(pos.x)
	var cz := floori(pos.z)
	var feet := pos.y - 0.9
	for h in [0.25, 1.0, 1.6]:
		if ship.blocks.has(Vector3i(cx, floori(feet + h), cz)):
			return true
	return false


# --- GROUND -------------------------------------------------------------------

## Walk on a surface whose local "up" is given, under gravity magnitude `gmag`.
## Used both for planets (up = -snapped gravity) and for standing inside a ship
## in space (up = ship's up, gmag = artificial gravity).
# Smoothly rotate the body so its local +Y aligns with `up` (stand upright).
func _align_up(up: Vector3, delta: float) -> void:
	var body_up := global_transform.basis.y
	var dot := clampf(body_up.dot(up), -1.0, 1.0)
	if dot < -0.9999:
		# nearly upside-down: nudge with a perpendicular axis to avoid a degenerate quat
		global_transform.basis = Basis(global_transform.basis.x, PI) * global_transform.basis
	elif dot < 0.9999:
		var full := Quaternion(body_up, up)
		var step := Quaternion.IDENTITY.slerp(full, clampf(delta * ALIGN_SPEED, 0.0, 1.0))
		global_transform.basis = Basis(step) * global_transform.basis
	global_transform.basis = global_transform.basis.orthonormalized()


func _walk(delta: float, up: Vector3, gmag: float, allow_jetpack: bool = true) -> void:
	_align_up(up, delta)

	# Yaw around local up; pitch the camera.
	if _look.x != 0.0:
		rotate(up, -_look.x * MOUSE_SENS)
	_pitch = clampf(_pitch - _look.y * MOUSE_SENS, -1.45, 1.45)
	_camera.rotation.x = _pitch
	_look = Vector2.ZERO

	# Movement on the tangent plane.
	var input := _move_input()
	var fwd := -global_transform.basis.z
	var right := global_transform.basis.x
	var wish := right * input.x + fwd * input.y
	wish = wish - up * wish.dot(up)
	if wish.length() > 0.001:
		wish = wish.normalized()

	# Split velocity into tangent (horizontal) and along-up (vertical) parts.
	var v_up := velocity.dot(up)
	var horiz := wish * WALK_SPEED

	v_up += -gmag * delta  # gravity pulls along -up (the snapped down axis)

	if is_on_floor():
		if v_up < 0.0:
			v_up = 0.0
		if Input.is_physical_key_pressed(KEY_SPACE):
			v_up = JUMP_SPEED
	elif allow_jetpack:
		# jetpack: hold jump to thrust up, crouch to thrust down (hybrid flight)
		if Input.is_physical_key_pressed(KEY_SPACE):
			v_up = minf(v_up + JETPACK_ACCEL * delta, JETPACK_MAX_SPEED)
		if Input.is_physical_key_pressed(KEY_SHIFT):
			v_up = maxf(v_up - JETPACK_ACCEL * delta, -JETPACK_MAX_SPEED)

	velocity = horiz + up * v_up
	up_direction = up
	move_and_slide()


# --- SWIMMING -----------------------------------------------------------------

const SWIM_SPEED := 6.0        # horizontal / dive-climb speed in water
const SWIM_ACCEL := 4.0        # how quickly velocity eases (water is draggy)
const SWIM_BUOY := 2.2         # gentle rise toward the surface when not diving

func _in_water(wp: Vector3) -> bool:
	if world == null:
		return false
	var p := world.nearest_planet(wp)
	if p == null or p.water_style != p.WATER_LIQUID:
		return false
	return p.get_id(p.world_to_voxel(wp)) == Blocks.WATER


# Buoyant, draggy movement: swim relative to the camera, hold Space to rise / Shift
# to dive, and float gently up to the surface when you let go.
func _swim(delta: float, up: Vector3) -> void:
	grounded = false
	_align_up(up, delta)
	if _look.x != 0.0:
		rotate(up, -_look.x * MOUSE_SENS)
	_pitch = clampf(_pitch - _look.y * MOUSE_SENS, -1.45, 1.45)
	_camera.rotation.x = _pitch
	_look = Vector2.ZERO

	var cam := _camera.global_transform.basis
	var input := _move_input()
	var wish := (-cam.z) * input.y + cam.x * input.x  # swim toward where you look
	var desired := Vector3.ZERO
	if wish.length() > 0.01:
		desired = wish.normalized() * SWIM_SPEED
	var vy := 0.0
	if Input.is_physical_key_pressed(KEY_SPACE): vy += 1.0
	if Input.is_physical_key_pressed(KEY_SHIFT): vy -= 1.0
	if vy != 0.0:
		desired += up * vy * SWIM_SPEED
	elif _in_water(global_position + up * 0.5):
		desired += up * SWIM_BUOY  # submerged & idle: bob up to the surface

	velocity = velocity.lerp(desired, clampf(delta * SWIM_ACCEL, 0.0, 1.0))
	up_direction = up
	move_and_slide()


# --- FLOAT --------------------------------------------------------------------

func _process_float(delta: float) -> void:
	# Free look: yaw around body up, pitch the camera. No forced orientation.
	if _look.x != 0.0:
		rotate(global_transform.basis.y, -_look.x * MOUSE_SENS)
	_pitch = clampf(_pitch - _look.y * MOUSE_SENS, -1.45, 1.45)
	_camera.rotation.x = _pitch
	_look = Vector2.ZERO

	var input := _move_input()
	var cam := _camera.global_transform.basis
	var fwd := -cam.z
	var right := cam.x
	var up := cam.y
	var vertical := 0.0
	if Input.is_physical_key_pressed(KEY_SPACE):
		vertical += 1.0
	if Input.is_physical_key_pressed(KEY_SHIFT):
		vertical -= 1.0

	var wish := (fwd * input.y + right * input.x + up * vertical)
	if wish.length() > 1.0:
		wish = wish.normalized()

	if wish.length() > 0.01:
		velocity = velocity.lerp(wish * FLY_SPEED, clampf(delta * FLY_ACCEL, 0.0, 1.0))
	else:
		velocity = velocity.lerp(Vector3.ZERO, clampf(delta * FLY_DAMP, 0.0, 1.0))

	up_direction = up
	move_and_slide()


## Nearest of the six cardinal directions to `v`, as a unit vector.
func _snap_to_axis(v: Vector3) -> Vector3:
	var ax := absf(v.x)
	var ay := absf(v.y)
	var az := absf(v.z)
	if ax >= ay and ax >= az:
		return Vector3(signf(v.x), 0, 0)
	elif ay >= az:
		return Vector3(0, signf(v.y), 0)
	return Vector3(0, 0, signf(v.z))


func _move_input() -> Vector2:
	var x := 0.0
	var y := 0.0
	if Input.is_physical_key_pressed(KEY_W): y += 1.0
	if Input.is_physical_key_pressed(KEY_S): y -= 1.0
	if Input.is_physical_key_pressed(KEY_D): x += 1.0
	if Input.is_physical_key_pressed(KEY_A): x -= 1.0
	return Vector2(x, y)


# --- block placing (right-click) ----------------------------------------------
# Breaking is handled by hold-to-mine in _process_mining.

func _edit_block(_break_it: bool) -> void:
	var place_id := _selected_id()
	if place_id == Blocks.AIR:
		return  # nothing selected / none left in this slot
	_ray.force_raycast_update()
	if not _ray.is_colliding():
		return
	var collider := _ray.get_collider()
	var point := _ray.get_collision_point()
	var normal := _ray.get_collision_normal()
	var probe := point + normal * 0.5  # into the empty neighbor cell

	if collider is Chunk:
		var planet: Planet = (collider as Chunk).planet
		var v := planet.world_to_voxel(probe)
		if planet.to_global(Vector3(v) + Vector3(0.5, 0.5, 0.5)).distance_to(global_position) > 1.1:
			planet.set_block(v, place_id)
			_consume_active()
	elif collider is Ship:
		var ship := collider as Ship
		var v := ship.world_to_voxel(probe)
		if ship.to_global(Vector3(v) + Vector3(0.5, 0.5, 0.5)).distance_to(global_position) > 1.1:
			ship.set_block(v, place_id)
			_consume_active()


# Hold left-click to break the targeted block; harder blocks take longer. Broken
# blocks are added to the inventory. Also sets `_look_name` for the HUD.
func _process_mining(delta: float) -> void:
	_look_name = ""
	_ray.force_raycast_update()
	if not _ray.is_colliding():
		_mine_key = ""
		_mine_time = 0.0
		return
	var collider := _ray.get_collider()
	var point := _ray.get_collision_point()
	var normal := _ray.get_collision_normal()
	var probe := point - normal * 0.5

	var id := Blocks.AIR
	var key := ""
	var planet: Planet = null
	var ship: Ship = null
	var v := Vector3i.ZERO
	if collider is Chunk:
		planet = (collider as Chunk).planet
		v = planet.world_to_voxel(probe)
		id = planet.get_id(v)
		key = "p%d:%d,%d,%d" % [planet.get_instance_id(), v.x, v.y, v.z]
	elif collider is Ship:
		ship = collider as Ship
		v = ship.world_to_voxel(probe)
		id = ship.get_id(v)
		key = "s%d:%d,%d,%d" % [ship.get_instance_id(), v.x, v.y, v.z]
	else:
		_mine_key = ""
		_mine_time = 0.0
		return

	if id == Blocks.AIR:
		_mine_key = ""
		_mine_time = 0.0
		return

	var use := Blocks.use_of(id)
	_look_name = Blocks.name_of(id) + ("  (" + use + ")" if use != "" else "")

	var holding := Input.mouse_mode == Input.MOUSE_MODE_CAPTURED and Input.is_mouse_button_pressed(MOUSE_BUTTON_LEFT)
	if not holding:
		_mine_key = ""
		_mine_time = 0.0
		return
	if key != _mine_key:
		_mine_key = key
		_mine_time = 0.0
		_mine_total = Blocks.hardness(id)
	_mine_time += delta
	if _mine_time >= _mine_total:
		if planet != null:
			planet.set_block(v, Blocks.AIR)
			planet.flow_water(v)  # let adjacent water pour into the gap
		elif ship != null:
			ship.set_block(v, Blocks.AIR)
		_add_item(id, 1)
		_refresh_slots()
		_mine_key = ""
		_mine_time = 0.0


## Start a new ship where the player is looking, oriented to their current frame.
func _start_ship() -> void:
	if world == null:
		return
	_ray.force_raycast_update()
	var up := -world.gravity_at(global_position).normalized()
	if up.length() < 0.1:
		up = global_transform.basis.y
	var fwd := -_camera.global_transform.basis.z
	var pos: Vector3
	if _ray.is_colliding():
		pos = _ray.get_collision_point() + _ray.get_collision_normal() * 0.5
	else:
		pos = global_position + fwd * 4.0
	world.spawn_ship(pos, up, fwd)


# --- UI -----------------------------------------------------------------------

# --- planet navigation markers ------------------------------------------------

func _update_markers() -> void:
	if world == null or _ui_layer == null:
		return
	var cam := get_viewport().get_camera_3d()
	if cam == null:
		return
	while _markers.size() < world.planets.size():
		var l := Label.new()
		l.add_theme_font_size_override("font_size", 14)
		l.modulate = Color(0.55, 0.9, 1.0)
		_ui_layer.add_child(l)
		_markers.append(l)

	var vp := get_viewport().get_visible_rect().size
	var center := vp * 0.5
	var margin := 52.0
	var inv := cam.global_transform.affine_inverse()
	for i in world.planets.size():
		var planet: Planet = world.planets[i]
		var lbl: Label = _markers[i]
		var wp := planet.global_position
		var dist := wp.distance_to(cam.global_position)
		if dist < planet.radius * 1.25:
			lbl.visible = false  # you're basically there; no need for a marker
			continue
		var localp := inv * wp                # planet in camera space (-Z is forward)
		var pos: Vector2
		var offscreen := true
		if localp.z < 0.0:
			pos = cam.unproject_position(wp)
			offscreen = pos.x < margin or pos.x > vp.x - margin or pos.y < margin or pos.y > vp.y - margin
		if offscreen:
			var d2 := Vector2(localp.x, -localp.y)
			if localp.z > 0.0:
				d2 = -d2                       # behind us: flip to point the right way
			if d2.length() < 0.001:
				d2 = Vector2(0, 1)
			pos = _clamp_to_edge(center, d2.normalized(), vp, margin)
			lbl.text = ">> %s  %s" % [planet.planet_name, _fmt_dist(dist)]
		else:
			lbl.text = "%s  %s" % [planet.planet_name, _fmt_dist(dist)]
		lbl.position = pos
		lbl.visible = true


func _clamp_to_edge(center: Vector2, dir: Vector2, vp: Vector2, margin: float) -> Vector2:
	var t := INF
	if dir.x > 0.0:
		t = minf(t, (vp.x - margin - center.x) / dir.x)
	elif dir.x < 0.0:
		t = minf(t, (margin - center.x) / dir.x)
	if dir.y > 0.0:
		t = minf(t, (vp.y - margin - center.y) / dir.y)
	elif dir.y < 0.0:
		t = minf(t, (margin - center.y) / dir.y)
	return center + dir * t


func _fmt_dist(d: float) -> String:
	if d >= 1000.0:
		return "%.1f km" % (d / 1000.0)
	return "%d m" % int(d)


func _build_ui() -> void:
	var layer := CanvasLayer.new()
	add_child(layer)
	_ui_layer = layer

	_crosshair = Label.new()
	_crosshair.text = "+"
	_crosshair.add_theme_font_size_override("font_size", 24)
	_crosshair.set_anchors_preset(Control.PRESET_CENTER)
	_crosshair.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	_crosshair.vertical_alignment = VERTICAL_ALIGNMENT_CENTER
	layer.add_child(_crosshair)

	_hotbar_label = Label.new()
	_hotbar_label.position = Vector2(16, 16)
	layer.add_child(_hotbar_label)

	_mode_label = Label.new()
	_mode_label.position = Vector2(16, 44)
	layer.add_child(_mode_label)

	_ship_label = Label.new()
	_ship_label.position = Vector2(16, 72)
	layer.add_child(_ship_label)

	# what you're aiming at + mining progress, just under the crosshair
	_target_label = Label.new()
	_target_label.set_anchors_preset(Control.PRESET_CENTER_TOP)
	_target_label.position = Vector2(0, 360)
	_target_label.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	_target_label.grow_horizontal = Control.GROW_DIRECTION_BOTH
	layer.add_child(_target_label)

	_build_inventory_ui(layer)

	var help := Label.new()
	help.position = Vector2(16, 108)
	help.text = "WASD move  |  Mouse look  |  Space up  |  Shift down  |  R-click place  |  Hold L-click mine\n" \
		+ "1-8 slot  |  Scroll = slot  |  E inventory  |  G ship  |  F cockpit  |  T EVA  |  Q/E roll  |  Esc\n" \
		+ "F5 save  |  F9 load  |  Build Cockpit + Thruster + hull, F to fly, hold Space to lift off. Aboard: F/T"
	help.modulate = Color(1, 1, 1, 0.55)
	layer.add_child(help)

	# transient save/load confirmation, top-center
	_toast_label = Label.new()
	_toast_label.set_anchors_preset(Control.PRESET_CENTER_TOP)
	_toast_label.position = Vector2(0, 24)
	_toast_label.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	_toast_label.grow_horizontal = Control.GROW_DIRECTION_BOTH
	_toast_label.add_theme_font_size_override("font_size", 22)
	_toast_label.visible = false
	layer.add_child(_toast_label)

	_update_ui()


func _toast(msg: String) -> void:
	if _toast_label == null:
		return
	_toast_label.text = msg
	_toast_label.visible = true
	_toast_time = 2.0


# Build the always-visible hotbar strip and the toggleable full-inventory grid.
func _build_inventory_ui(layer: CanvasLayer) -> void:
	# hotbar strip, bottom-center
	var hb := HBoxContainer.new()
	hb.add_theme_constant_override("separation", 4)
	hb.set_anchors_preset(Control.PRESET_CENTER_BOTTOM)
	hb.grow_horizontal = Control.GROW_DIRECTION_BOTH
	hb.position = Vector2(-8 * 32, -76)
	layer.add_child(hb)
	for i in HOTBAR_SLOTS:
		_hotbar_cells.append(_make_slot(hb, i, false))

	# full inventory overlay (E)
	_inv_panel = Panel.new()
	_inv_panel.set_anchors_preset(Control.PRESET_CENTER)
	_inv_panel.custom_minimum_size = Vector2(8 * 60 + 24, 4 * 60 + 48)
	_inv_panel.size = _inv_panel.custom_minimum_size
	_inv_panel.position = -_inv_panel.size * 0.5
	_inv_panel.visible = false
	layer.add_child(_inv_panel)
	var title := Label.new()
	title.text = "Inventory"
	title.position = Vector2(14, 8)
	_inv_panel.add_child(title)
	var grid := GridContainer.new()
	grid.columns = HOTBAR_SLOTS
	grid.add_theme_constant_override("h_separation", 4)
	grid.add_theme_constant_override("v_separation", 4)
	grid.position = Vector2(12, 36)
	_inv_panel.add_child(grid)
	for i in SLOTS:
		_grid_cells.append(_make_slot(grid, i, true))


# One slot cell: colored square + count. `clickable` grid cells select the slot.
func _make_slot(parent: Node, index: int, clickable: bool) -> Dictionary:
	var root: Control
	if clickable:
		var b := Button.new()
		b.pressed.connect(func():
			active_slot = index
			_refresh_slots())
		root = b
	else:
		root = Panel.new()
	root.custom_minimum_size = Vector2(56, 56)
	parent.add_child(root)
	var swatch := ColorRect.new()
	swatch.set_anchors_preset(Control.PRESET_FULL_RECT)
	swatch.offset_left = 6; swatch.offset_top = 6
	swatch.offset_right = -6; swatch.offset_bottom = -6
	swatch.mouse_filter = Control.MOUSE_FILTER_IGNORE
	root.add_child(swatch)
	var count := Label.new()
	count.set_anchors_preset(Control.PRESET_BOTTOM_RIGHT)
	count.offset_left = -30; count.offset_top = -22
	count.mouse_filter = Control.MOUSE_FILTER_IGNORE
	root.add_child(count)
	return {"root": root, "swatch": swatch, "count": count}


func _refresh_slots() -> void:
	active_slot = clampi(active_slot, 0, SLOTS - 1)
	for i in _hotbar_cells.size():
		_paint_slot(_hotbar_cells[i], i)
	for i in _grid_cells.size():
		_paint_slot(_grid_cells[i], i)


func _paint_slot(cell: Dictionary, index: int) -> void:
	var s = inv[index]
	var swatch: ColorRect = cell["swatch"]
	var count: Label = cell["count"]
	if s["count"] > 0:
		swatch.color = Blocks.color_of(s["id"])
		count.text = str(s["count"])
	else:
		swatch.color = Color(0.15, 0.15, 0.18, 0.6)
		count.text = ""
	# highlight the active slot
	cell["root"].modulate = Color(1.4, 1.4, 0.7) if index == active_slot else Color(1, 1, 1)


func _update_ui() -> void:
	if _hotbar_label == null:
		return
	_update_markers()

	# targeted block + mining progress bar (hidden while piloting)
	if _target_label != null:
		if piloting != null:
			_target_label.text = ""
		else:
			var t := _look_name
			if _mine_key != "" and _mine_total > 0.0:
				var filled := int(clampf(_mine_time / _mine_total, 0.0, 1.0) * 10.0)
				t += "  [" + "#".repeat(filled) + "-".repeat(10 - filled) + "]"
			_target_label.text = t

	if eva:
		_hotbar_label.text = "EVA  (T to climb back in  |  aim + click to repair)"
		_mode_label.text = "On tether  |  6-axis thrust  |  holding: %s" % Blocks.name_of(_selected_id())
		_ship_label.text = ""
		return

	if aboard != null and is_instance_valid(aboard):
		var spd := aboard.velocity.length()
		_hotbar_label.text = "ABOARD SHIP  (walk around -- F cockpit to pilot, T to EVA)"
		_mode_label.text = "Interior gravity  |  %s" % ("cruising %.0f m/s" % spd if spd > 0.5 else "holding station")
		_ship_label.text = ""
		return

	if piloting != null and is_instance_valid(piloting):
		var g := world.gravity_at(piloting.global_position) if world else Vector3.ZERO
		var pl := world.nearest_planet(piloting.global_position) if world else null
		var alt := 0.0
		if pl != null:
			alt = pl.altitude(piloting.global_position)
		var up := -g.normalized() if g.length() > 0.01 else Vector3.UP
		var vspeed := piloting.velocity.dot(up)  # +up / -down
		_hotbar_label.text = "PILOTING  (F to exit)"
		if piloting.in_gravity:
			_mode_label.text = "LAUNCH/LAND ASSIST  |  Alt %.0f m  |  V-speed %+.1f m/s" % [alt, vspeed]
			if piloting.landed:
				_ship_label.text = "LANDED  (hold Space to lift off)"
			elif alt < 20.0 and absf(vspeed) < 6.0:
				_ship_label.text = "CLEAR TO LAND -- ease down with Shift"
			else:
				_ship_label.text = "Climb (Space) to break orbit and unlock maneuvering"
		else:
			_mode_label.text = "FREE FLIGHT  |  Speed %.0f m/s  |  Alt %.0f m" % [piloting.velocity.length(), alt]
			_ship_label.text = "Full 6-axis maneuvering"
		return

	var held := _selected_id()
	_hotbar_label.text = "Holding: %s" % (Blocks.name_of(held) if held != Blocks.AIR else "(empty slot)")
	var p := world.nearest_planet(global_position) if world else null
	var pname := p.planet_name if p else "Deep Space"
	_mode_label.text = "%s  |  %s" % ["GROUNDED" if grounded else "FLOATING (6-axis)", pname]

	var ship := world.nearest_ship(global_position) if world else null
	if ship != null and ship.global_position.distance_to(global_position) < 40.0:
		var st := ship.get_status()
		var near: bool = ship.global_position.distance_to(global_position) < 6.0
		var prompt := ""
		if st["can_fly"] and near:
			prompt = "  [F to pilot]"
		elif near and not st["can_fly"]:
			prompt = "  [needs cockpit + thruster + 4 blocks to fly]"
		_ship_label.text = "Ship: %d blocks  Cockpit %s  Thrusters %d%s" % [
			st["count"], "OK" if st["cockpit"] else "--", st["thrusters"], prompt]
	else:
		_ship_label.text = ""
