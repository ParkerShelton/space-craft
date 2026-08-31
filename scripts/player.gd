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
const BARE_MINE_MULT := 2.5       # bare-hand mining is slow; a drill divides this
var mine_power := 1.0             # >1 once you craft a drill (Phase 2)

var world: WorldManager           # set by main.gd
var grounded := false

# --- inventory (slots; you can only place what you have) ---
const SLOTS := 32
const HOTBAR_SLOTS := 8
const STACK_MAX := 99
# each slot: {"id": int, "count": int, "props": Dictionary, "src": String}
# props/src are set for refined materials & crafted gear; plain blocks leave them empty.
var inv: Array = []
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
var _outline: MeshInstance3D       # wireframe box around the block under the crosshair
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

# --- crafting stations ---
var _station_open: Station = null  # non-null while a station panel is open
var _station_panel: Panel
var _station_title: Label
var _station_cells: Array = []     # storage slot views (rebuilt per open; may span a chest group)
var _stor_container: Control       # holds the (absolutely-positioned) storage cells
var _stor_map: Array = []          # storage cell index -> {st: Station, slot: int}
var _pinv_cells: Array = []        # player-inventory slot views inside the station panel
var _pinv_label: Label             # "Your inventory" header (repositioned per station size)
var _pinv_grid: GridContainer      # the inventory grid inside the station panel
var _rx := 0                       # right-column x
var _station_store_label: Label    # "<station> contents" header above its storage
var _left_header: Label            # "Blueprints" / "Actions" header on the left column
var _refine_btn: Button            # Smelter action
var _craft_row: Control            # holds per-station craft buttons
var _craft_buttons: Array = []     # current station's craft buttons
var _preview_label: Label          # live craft-stat preview (Fabricator/Shipworks)
var _build_buttons: Array = []     # hand-assemble-station buttons in the inventory panel
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

	# wireframe outline that hugs the block under the crosshair
	_outline = MeshInstance3D.new()
	_outline.mesh = _make_outline_mesh()
	var om := StandardMaterial3D.new()
	om.shading_mode = BaseMaterial3D.SHADING_MODE_UNSHADED
	om.albedo_color = Color(0, 0, 0, 0.9)
	om.no_depth_test = false
	_outline.material_override = om
	_outline.visible = false
	if world != null:
		world.add_child(_outline)
	else:
		get_parent().add_child(_outline)

	_init_inventory()
	_build_ui()
	_refresh_slots()


# 12-edge wireframe unit cube (slightly inflated) used as the targeting outline.
func _make_outline_mesh() -> ArrayMesh:
	var lo := -0.002
	var hi := 1.002
	var c := [
		Vector3(lo, lo, lo), Vector3(hi, lo, lo), Vector3(hi, hi, lo), Vector3(lo, hi, lo),
		Vector3(lo, lo, hi), Vector3(hi, lo, hi), Vector3(hi, hi, hi), Vector3(lo, hi, hi)]
	var edges := [[0, 1], [1, 2], [2, 3], [3, 0], [4, 5], [5, 6], [6, 7], [7, 4],
		[0, 4], [1, 5], [2, 6], [3, 7]]
	var verts := PackedVector3Array()
	for e in edges:
		verts.append(c[e[0]])
		verts.append(c[e[1]])
	var arr := []
	arr.resize(Mesh.ARRAY_MAX)
	arr[Mesh.ARRAY_VERTEX] = verts
	var mesh := ArrayMesh.new()
	mesh.add_surface_from_arrays(Mesh.PRIMITIVE_LINES, arr)
	return mesh


# --- inventory ---------------------------------------------------------------

func _init_inventory() -> void:
	inv.clear()
	for i in SLOTS:
		inv.append({"id": Blocks.AIR, "count": 0, "props": {}, "src": "", "mat": {}})
	# starting kit so you can build a ship and terraform right away
	_add_item(Blocks.COCKPIT, 2)
	_add_item(Blocks.THRUSTER, 8)
	_add_item(Blocks.METAL, 64)
	_add_item(Blocks.GRASS, 64)
	_add_item(Blocks.DIRT, 64)
	_add_item(Blocks.ROCK, 64)
	_add_item(Blocks.WOOD, 32)
	_add_item(Blocks.LEAF_0, 32)


# Add n of an item; fills matching stacks first, then empty slots. Returns leftover.
# Items with different props/src (e.g. copper from different planets) don't stack.
func _add_item(id: int, n: int, props: Dictionary = {}, src: String = "", mat: Dictionary = {}) -> int:
	if id == Blocks.AIR or n <= 0:
		return n
	for s in inv:
		if s["id"] == id and s.get("src", "") == src and s["count"] > 0 and s["count"] < STACK_MAX:
			var add: int = mini(n, STACK_MAX - s["count"])
			s["count"] += add
			n -= add
			if n <= 0:
				return 0
	for s in inv:
		if s["count"] == 0:
			s["id"] = id
			s["props"] = props
			s["src"] = src
			s["mat"] = mat
			var add: int = mini(n, STACK_MAX)
			s["count"] = add
			n -= add
			if n <= 0:
				return 0
	return n  # inventory full; leftover dropped


func _count_item(id: int) -> int:
	var total := 0
	for s in inv:
		if s["id"] == id:
			total += s["count"]
	return total


func _remove_item(id: int, n: int) -> int:
	for s in inv:
		if s["id"] == id and s["count"] > 0:
			var take: int = mini(n, s["count"])
			s["count"] -= take
			n -= take
			if s["count"] == 0:
				s["id"] = Blocks.AIR
			if n <= 0:
				break
	return n


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
		if inv_open or _station_open != null:
			return  # a panel is open: clicks go to the UI
		if Input.mouse_mode != Input.MOUSE_MODE_CAPTURED:
			Input.mouse_mode = Input.MOUSE_MODE_CAPTURED
			return
		if piloting:
			return  # no building while flying
		if event.button_index == MOUSE_BUTTON_RIGHT:
			# right-click a station to open its own menu; otherwise place a block
			var st := _looked_at_station()
			if st != null and not eva:
				_open_station(st)
			else:
				_edit_block(false)  # placing is instant; breaking is hold-to-mine
		elif event.button_index == MOUSE_BUTTON_WHEEL_UP:
			_cycle_slot(-1)
		elif event.button_index == MOUSE_BUTTON_WHEEL_DOWN:
			_cycle_slot(1)
	elif event is InputEventKey and event.pressed and not event.echo:
		if event.keycode == KEY_ESCAPE:
			if _station_open != null:
				_close_station()
			elif inv_open:
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
			if piloting != null:
				pass  # E rolls the ship while piloting -- not the inventory
			elif _station_open != null:
				_close_station()
			else:
				_toggle_inventory()
		elif _station_open != null:
			return  # a station panel is open: swallow other keys
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
		if _outline != null:
			_outline.visible = false
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
		# align to the snapped axis (like walking) so you stay upright vs gravity
		var sup := -_snap_to_axis(g) if g.length() > 0.01 else Vector3.UP
		_swim(delta, sup)
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


# --- voxel targeting ----------------------------------------------------------
# The physics ray tells us WHICH object we're aiming at + a surface point; a short
# DDA march through that object's voxel grid then finds the exact block (and the
# empty cell in front for placing). This is far more accurate than deriving the
# cell from the collision normal (which is unreliable with double-sided collision).

func _raycast_voxel() -> Dictionary:
	_ray.force_raycast_update()
	if not _ray.is_colliding():
		return {}
	var collider := _ray.get_collider()
	var hit := _ray.get_collision_point()
	var origin := _camera.global_position
	var dir := hit - origin
	if dir.length() < 0.0001:
		dir = -_camera.global_transform.basis.z
	dir = dir.normalized()
	if collider is Chunk:
		return _dda((collider as Chunk).planet, origin, dir, hit, "planet")
	if collider is Ship:
		return _dda(collider, origin, dir, hit, "ship")
	if collider is Station:
		return {"kind": "station", "obj": collider, "hit": false}
	return {}


func _dda(obj: Object, origin_w: Vector3, dir_w: Vector3, hit_w: Vector3, kind: String) -> Dictionary:
	# march in the object's local voxel space (planets are axis-aligned; ships rotate)
	var ld: Vector3 = (obj.global_transform.basis.inverse() * dir_w).normalized()
	var start: Vector3 = obj.to_local(hit_w) - ld * 0.06  # step just outside the surface
	var v := Vector3i(floori(start.x), floori(start.y), floori(start.z))
	var step := Vector3i(1 if ld.x >= 0.0 else -1, 1 if ld.y >= 0.0 else -1, 1 if ld.z >= 0.0 else -1)
	var tmax := Vector3(_tmax(start.x, ld.x), _tmax(start.y, ld.y), _tmax(start.z, ld.z))
	var tdelta := Vector3(_tdelta(ld.x), _tdelta(ld.y), _tdelta(ld.z))
	var normal := Vector3i.ZERO
	var prev := v
	for i in 14:
		var id: int = obj.get_id(v)
		if id != Blocks.AIR and id != Blocks.WATER:
			return {"hit": true, "kind": kind, "obj": obj, "voxel": v, "place": prev, "normal": normal, "id": id}
		prev = v
		if tmax.x <= tmax.y and tmax.x <= tmax.z:
			v.x += step.x
			tmax.x += tdelta.x
			normal = Vector3i(-step.x, 0, 0)
		elif tmax.y <= tmax.z:
			v.y += step.y
			tmax.y += tdelta.y
			normal = Vector3i(0, -step.y, 0)
		else:
			v.z += step.z
			tmax.z += tdelta.z
			normal = Vector3i(0, 0, -step.z)
	return {}


func _tmax(s: float, d: float) -> float:
	if absf(d) < 1e-9:
		return INF
	var cell := floorf(s)
	return (cell + 1.0 - s) / d if d > 0.0 else (s - cell) / -d


func _tdelta(d: float) -> float:
	return INF if absf(d) < 1e-9 else absf(1.0 / d)


func _update_outline(tgt: Dictionary) -> void:
	if _outline == null:
		return
	var show: bool = not tgt.is_empty() and tgt.get("hit", false) \
		and not inv_open and _station_open == null and Input.mouse_mode == Input.MOUSE_MODE_CAPTURED
	if not show:
		_outline.visible = false
		return
	var obj = tgt["obj"]
	var v: Vector3i = tgt["voxel"]
	_outline.global_transform = Transform3D(obj.global_transform.basis, obj.to_global(Vector3(v)))
	_outline.visible = true


# --- block placing (right-click) ----------------------------------------------
# Breaking is handled by hold-to-mine in _process_mining.

func _edit_block(_break_it: bool) -> void:
	var place_id := _selected_id()
	if place_id == Blocks.AIR:
		return  # nothing selected / none left in this slot
	if Blocks.is_station(place_id):
		_place_station(place_id)
		return
	if not Blocks.is_placeable_block(place_id):
		_toast("Can't place that — use a station")
		return
	var tgt := _raycast_voxel()
	if tgt.is_empty() or not tgt.get("hit", false):
		return
	var obj = tgt["obj"]
	var pv: Vector3i = tgt["place"]
	if tgt["kind"] == "planet":
		if obj.to_global(Vector3(pv) + Vector3(0.5, 0.5, 0.5)).distance_to(global_position) > 1.1:
			obj.set_block(pv, place_id)
			_consume_active()
	elif tgt["kind"] == "ship":
		if obj.to_global(Vector3(pv) + Vector3(0.5, 0.5, 0.5)).distance_to(global_position) > 1.1:
			# crafted ship blocks carry their material stats onto the ship
			obj.set_block(pv, place_id, inv[active_slot].get("props", {}))
			_consume_active()


## Place a crafting station in the empty cell you're aiming at -- on a planet
## surface OR on a ship (where it rides along, so bigger ships become mobile bases).
## Consumes it from the active slot.
func _place_station(id: int) -> void:
	if world == null:
		return
	var tgt := _raycast_voxel()
	if tgt.is_empty() or not tgt.get("hit", false):
		return
	var obj = tgt["obj"]
	var pv: Vector3i = tgt["place"]
	if tgt["kind"] == "planet":
		var corner: Vector3 = obj.to_global(Vector3(pv))
		if corner.distance_to(global_position) < 1.1:
			return  # don't place inside yourself
		if id == Blocks.CHEST and _chest_cluster_size_at(world, Vector3i(corner.round())) > MAX_CHEST_GROUP:
			_toast("Chest cluster is full (max %d)" % MAX_CHEST_GROUP)
			return
		var g := world.gravity_at(corner)
		var up := (-g).normalized() if g.length() > 0.01 else Vector3.UP
		world.spawn_station(id, corner, up, -global_transform.basis.z)
		_consume_active()
		_toast(Blocks.name_of(id) + " placed")
	elif tgt["kind"] == "ship":
		if id == Blocks.CHEST and _chest_cluster_size_at(obj, pv) > MAX_CHEST_GROUP:
			_toast("Chest cluster is full (max %d)" % MAX_CHEST_GROUP)
			return
		world.spawn_station_on_ship(id, obj, pv)
		_consume_active()
		_toast(Blocks.name_of(id) + " mounted on ship")
	else:
		_toast("Aim at the ground or a ship")


# Hold left-click to break the targeted block; harder blocks take longer. Broken
# blocks are added to the inventory. Also sets `_look_name` for the HUD.
func _process_mining(delta: float) -> void:
	_look_name = ""
	var tgt := _raycast_voxel()
	_update_outline(tgt)
	if tgt.is_empty() or not tgt.get("hit", false):
		_mine_key = ""
		_mine_time = 0.0
		return

	var kind: String = tgt["kind"]
	var obj = tgt["obj"]
	var v: Vector3i = tgt["voxel"]
	var id: int = tgt["id"]
	var planet: Planet = obj if kind == "planet" else null
	var ship: Ship = obj if kind == "ship" else null
	var key := "%s%d:%d,%d,%d" % [kind, obj.get_instance_id(), v.x, v.y, v.z]

	# Ore is a procedural, unidentified material until refined; everything else
	# shows its name + use.
	var is_ore := planet != null and Blocks.is_ore(id)
	var od: Dictionary = planet.ore_def(id) if is_ore else {}
	if is_ore:
		_look_name = od.get("name", "Ore") + " Ore  (unidentified)"
	else:
		var use := Blocks.use_of(id)
		_look_name = Blocks.name_of(id) + ("  (" + use + ")" if use != "" else "")

	# High-tier ore is too hard for weak tools -- that gate is itself the tier hint.
	var hardness := Blocks.hardness(id)
	if is_ore:
		hardness = planet.ore_hardness(id)
		if mine_power < planet.ore_min_power(id):
			_look_name = od.get("name", "Ore") + " Ore  — too hard, needs a stronger drill"
			_mine_key = ""
			_mine_time = 0.0
			return

	var holding := Input.mouse_mode == Input.MOUSE_MODE_CAPTURED and Input.is_mouse_button_pressed(MOUSE_BUTTON_LEFT)
	if not holding:
		_mine_key = ""
		_mine_time = 0.0
		return
	if key != _mine_key:
		_mine_key = key
		_mine_time = 0.0
		_mine_total = hardness * BARE_MINE_MULT / mine_power
	_mine_time += delta
	if _mine_time >= _mine_total:
		if planet != null:
			planet.set_block(v, Blocks.AIR)
			planet.flow_water(v)  # let adjacent water pour into the gap
			if is_ore:
				_add_item(id, 1, od["props"], planet.planet_name,
					{"name": od["name"], "color": od["color"], "tier": od["tier"]})
			else:
				_add_item(id, 1)
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
	_build_station_ui(layer)

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
		_hotbar_cells.append(_make_slot(hb, i, "none"))

	# full inventory overlay (E): inventory grid on the left, a scrollable "Craft"
	# list on the right (scrolls instead of growing as recipes are added)
	var grid_w := HOTBAR_SLOTS * 60
	var grid_h := 4 * 60
	var craft_x := 12 + grid_w + 16
	var craft_w := 220
	_inv_panel = Panel.new()
	_inv_panel.set_anchors_preset(Control.PRESET_CENTER)
	_inv_panel.custom_minimum_size = Vector2(craft_x + craft_w + 12, 36 + grid_h + 16)
	_inv_panel.size = _inv_panel.custom_minimum_size
	_inv_panel.position = -_inv_panel.size * 0.5
	_inv_panel.visible = false
	layer.add_child(_inv_panel)
	var title := Label.new()
	title.text = "Inventory  (drag to rearrange)"
	title.position = Vector2(14, 8)
	_inv_panel.add_child(title)
	var grid := GridContainer.new()
	grid.columns = HOTBAR_SLOTS
	grid.add_theme_constant_override("h_separation", 4)
	grid.add_theme_constant_override("v_separation", 4)
	grid.position = Vector2(12, 36)
	_inv_panel.add_child(grid)
	for i in SLOTS:
		_grid_cells.append(_make_slot(grid, i, "select"))

	# --- crafting column: a scrolling list of hand recipes ---
	var chead := Label.new()
	chead.text = "Craft"
	chead.modulate = Color(1, 1, 1, 0.7)
	chead.position = Vector2(craft_x, 8)
	_inv_panel.add_child(chead)
	var scroll := ScrollContainer.new()
	scroll.position = Vector2(craft_x, 36)
	scroll.custom_minimum_size = Vector2(craft_w, grid_h)
	scroll.size = Vector2(craft_w, grid_h)
	scroll.horizontal_scroll_mode = ScrollContainer.SCROLL_MODE_DISABLED
	_inv_panel.add_child(scroll)
	var vbox := VBoxContainer.new()
	vbox.add_theme_constant_override("separation", 4)
	vbox.custom_minimum_size = Vector2(craft_w - 16, 0)
	scroll.add_child(vbox)
	for idx in Blocks.HAND_RECIPES.size():
		var b := Button.new()
		b.custom_minimum_size = Vector2(craft_w - 18, 44)
		b.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
		b.pressed.connect(_do_recipe.bind(idx))
		vbox.add_child(b)
		_build_buttons.append({"btn": b, "idx": idx})


# One slot cell: colored square + count. `mode`: "none" = display only,
# "select" = click picks the active slot, "inv"/"stor" = drag source & drop target
# (inventory slot / station-storage slot). Items are moved by dragging.
func _make_slot(parent: Node, index: int, mode: String) -> Dictionary:
	var root: Control
	if mode == "select":
		var b := Button.new()
		b.pressed.connect(_on_slot_pressed.bind(index))
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
	# drag & drop: "select"/"to_station" cells map to inventory slots, "from_station"
	# to the open station's storage
	var dcont := ""
	if mode == "select" or mode == "to_station":
		dcont = "inv"
	elif mode == "from_station":
		dcont = "stor"
	if dcont != "":
		root.set_drag_forwarding(
			_slot_get_drag.bind(dcont, index, root),
			_slot_can_drop.bind(dcont, index),
			_slot_do_drop.bind(dcont, index))
	return {"root": root, "swatch": swatch, "count": count}


func _on_slot_pressed(index: int) -> void:
	active_slot = index
	_refresh_slots()


# --- drag & drop --------------------------------------------------------------

func _slot_ref(cont: String, index: int) -> Dictionary:
	if cont == "inv":
		return inv[index]
	if cont == "stor" and index >= 0 and index < _stor_map.size():
		var m: Dictionary = _stor_map[index]
		var st: Station = m["st"]
		if is_instance_valid(st) and int(m["slot"]) < st.storage.size():
			return st.storage[int(m["slot"])]
	return {}


func _slot_get_drag(_at: Vector2, cont: String, index: int, root: Control) -> Variant:
	var slot := _slot_ref(cont, index)
	if slot.is_empty() or int(slot["count"]) <= 0:
		return null
	var pv := ColorRect.new()
	pv.size = Vector2(44, 44)
	pv.position = Vector2(-22, -22)
	var mat: Dictionary = slot.get("mat", {})
	pv.color = mat["color"] if mat.has("color") else Blocks.color_of(slot["id"])
	var wrap := Control.new()
	wrap.add_child(pv)
	root.set_drag_preview(wrap)
	return {"cont": cont, "index": index}


func _slot_can_drop(_at: Vector2, data: Variant, _cont: String, _index: int) -> bool:
	return typeof(data) == TYPE_DICTIONARY and data.has("cont")


func _slot_do_drop(_at: Vector2, data: Variant, cont: String, index: int) -> void:
	_transfer(data["cont"], int(data["index"]), cont, index)


func _clear_slot(s: Dictionary) -> void:
	s["id"] = Blocks.AIR
	s["count"] = 0
	s["props"] = {}
	s["src"] = ""
	s["mat"] = {}


func _copy_slot(src: Dictionary, dst: Dictionary) -> void:
	dst["id"] = src["id"]
	dst["count"] = src["count"]
	dst["props"] = src.get("props", {})
	dst["src"] = src.get("src", "")
	dst["mat"] = src.get("mat", {})


func _transfer(fc: String, fi: int, tc: String, ti: int) -> void:
	if fc == tc and fi == ti:
		return
	var from := _slot_ref(fc, fi)
	var to := _slot_ref(tc, ti)
	if from.is_empty() or to.is_empty() or int(from["count"]) <= 0:
		return
	# dropping INTO a machine's storage must match what it accepts (chests take all)
	if tc == "stor" and fc != "stor" and ti < _stor_map.size():
		var tst: Station = _stor_map[ti]["st"]
		if tst.kind == Blocks.SMELTER and not Blocks.is_ore(from["id"]):
			_toast("Smelter takes raw ore")
			return
		if tst.kind == Blocks.FABRICATOR and not Blocks.is_refined(from["id"]):
			_toast("Fabricator takes refined material")
			return
	if to["count"] > 0 and to["id"] == from["id"] and to.get("src", "") == from.get("src", ""):
		var cap: int = STACK_MAX if tc == "inv" else 100000
		var mv: int = mini(cap - to["count"], from["count"])
		to["count"] += mv
		from["count"] -= mv
		if from["count"] <= 0:
			_clear_slot(from)
	elif to["count"] == 0:
		_copy_slot(from, to)
		_clear_slot(from)
	else:
		var tmp := {"id": to["id"], "count": to["count"], "props": to.get("props", {}),
			"src": to.get("src", ""), "mat": to.get("mat", {})}
		_copy_slot(from, to)
		from["id"] = tmp["id"]
		from["count"] = tmp["count"]
		from["props"] = tmp["props"]
		from["src"] = tmp["src"]
		from["mat"] = tmp["mat"]
	_refresh_slots()
	_refresh_station_ui()


func _refresh_slots() -> void:
	active_slot = clampi(active_slot, 0, SLOTS - 1)
	for i in _hotbar_cells.size():
		_paint_cell(_hotbar_cells[i], inv[i], i == active_slot)
	for i in _grid_cells.size():
		_paint_cell(_grid_cells[i], inv[i], i == active_slot)
	_update_mine_power()
	_refresh_build_buttons()


# Your effective mining power is the best drill you carry (bare hands = 1.0). This
# sets mining speed and which ore tiers you can break.
func _update_mine_power() -> void:
	var best := 1.0
	for s in inv:
		if s["id"] == Blocks.DRILL and s["count"] > 0:
			best = maxf(best, float(s.get("mat", {}).get("power", 1.0)))
	mine_power = best


# Paint any slot cell from a slot dict. `highlight` toggles the active-slot glow.
func _paint_cell(cell: Dictionary, slot: Dictionary, highlight: bool) -> void:
	var swatch: ColorRect = cell["swatch"]
	var count: Label = cell["count"]
	if not slot.is_empty() and slot["count"] > 0:
		var mat: Dictionary = slot.get("mat", {})
		swatch.color = mat["color"] if mat.has("color") else Blocks.color_of(slot["id"])
		count.text = str(slot["count"])
		cell["root"].tooltip_text = _item_tooltip(slot)
	else:
		swatch.color = Color(0.15, 0.15, 0.18, 0.6)
		count.text = ""
		cell["root"].tooltip_text = ""
	cell["root"].modulate = Color(1.4, 1.4, 0.7) if highlight else Color(1, 1, 1)


# Hover text. Raw ore stays unidentified (tier & stats hidden); a refined material
# shows its tier and property bars. Source planet is shown for both.
func _item_tooltip(slot: Dictionary) -> String:
	var id: int = slot["id"]
	var mat: Dictionary = slot.get("mat", {})
	var mname: String = mat.get("name", Blocks.name_of(id))
	var src: String = slot.get("src", "")
	var suffix := ("  ·  " + src) if src != "" else ""
	if Blocks.is_gear(id):
		var power := float(mat.get("power", 1.0))
		return "%s Drill%s\nMining power %.1f — breaks up to Tier %d" % [
			mname, suffix, power, Blocks.max_tier_for_power(power)]
	if Blocks.is_ore(id):
		return "%s Ore%s\nUnidentified — refine to reveal its tier & stats" % [mname, suffix]
	if Blocks.is_refined(id):
		var tier: int = int(mat.get("tier", 0))
		var props: Dictionary = slot.get("props", {})
		var lines := ["Refined %s%s  (%s · Tier %d)" % [mname, suffix, Blocks.TIER_NAMES[tier], tier]]
		for k in Blocks.PROP_KEYS:
			lines.append("%s: %d" % [Blocks.PROP_LABELS[k], int(props.get(k, 0))])
		return "\n".join(lines)
	# crafted ship part (thruster/hull) carrying a material's stats
	var cprops: Dictionary = slot.get("props", {})
	if not cprops.is_empty() and mat.has("name"):
		var clines := ["%s %s%s" % [mname, Blocks.name_of(id), suffix]]
		for k in Blocks.PROP_KEYS:
			clines.append("%s: %d" % [Blocks.PROP_LABELS[k], int(cprops.get(k, 0))])
		return "\n".join(clines)
	# ordinary block / item
	var use := Blocks.use_of(id)
	return Blocks.name_of(id) + ("\n" + use if use != "" else "")


# --- station build recipes (hand-assembled from carried materials) ------------

func _count_refined() -> int:
	var total := 0
	for s in inv:
		if Blocks.is_refined(s["id"]):
			total += s["count"]
	return total


func _remove_refined(n: int) -> int:
	for s in inv:
		if Blocks.is_refined(s["id"]) and s["count"] > 0:
			var take: int = mini(n, s["count"])
			s["count"] -= take
			n -= take
			if s["count"] == 0:
				s["id"] = Blocks.AIR
			if n <= 0:
				break
	return n


func _count_any(ids: Array) -> int:
	var total := 0
	for s in inv:
		if s["id"] in ids:
			total += s["count"]
	return total


func _remove_any(ids: Array, n: int) -> void:
	for s in inv:
		if s["id"] in ids and s["count"] > 0:
			var take: int = mini(n, s["count"])
			s["count"] -= take
			n -= take
			if s["count"] == 0:
				s["id"] = Blocks.AIR
			if n <= 0:
				break


func _recipe_afford(reqs: Array) -> bool:
	for r in reqs:
		if r.has("refined"):
			if _count_refined() < int(r["n"]):
				return false
		elif r.has("any"):
			if _count_any(r["any"]) < int(r["n"]):
				return false
		elif _count_item(int(r["id"])) < int(r["n"]):
			return false
	return true


func _recipe_consume(reqs: Array) -> void:
	for r in reqs:
		if r.has("refined"):
			_remove_refined(int(r["n"]))
		elif r.has("any"):
			_remove_any(r["any"], int(r["n"]))
		else:
			_remove_item(int(r["id"]), int(r["n"]))


func _recipe_text(recipe: Dictionary) -> String:
	var parts := []
	for r in recipe["reqs"]:
		if r.has("refined"):
			parts.append("%d Refined Material" % int(r["n"]))
		elif r.has("any"):
			parts.append("%d %s" % [int(r["n"]), r.get("label", "items")])
		else:
			parts.append("%d %s" % [int(r["n"]), Blocks.name_of(int(r["id"]))])
	var out: int = recipe["out"]
	var n: int = recipe.get("n", 1)
	var verb := "Build" if Blocks.is_station(out) else "Craft"
	var out_txt := Blocks.name_of(out) if n == 1 else ("%d %s" % [n, Blocks.name_of(out)])
	return "%s %s  (%s)" % [verb, out_txt, ",  ".join(parts)]


func _refresh_build_buttons() -> void:
	for e in _build_buttons:
		var recipe: Dictionary = Blocks.HAND_RECIPES[e["idx"]]
		e["btn"].text = _recipe_text(recipe)
		e["btn"].disabled = not _recipe_afford(recipe["reqs"])


func _do_recipe(idx: int) -> void:
	var recipe: Dictionary = Blocks.HAND_RECIPES[idx]
	if not _recipe_afford(recipe["reqs"]):
		_toast("Missing materials")
		return
	_recipe_consume(recipe["reqs"])
	_add_item(int(recipe["out"]), int(recipe.get("n", 1)))
	_toast("Crafted " + Blocks.name_of(int(recipe["out"])))
	_refresh_slots()


# --- crafting stations --------------------------------------------------------

const _LEFT_W := 168   # left column (blueprints/actions) width
const _STORE_COLS := 8 # storage cells per row
func _build_station_ui(layer: CanvasLayer) -> void:
	_rx = 12 + _LEFT_W + 12            # right column x
	var rx := _rx
	var grid_w := _STORE_COLS * 60
	_station_panel = Panel.new()
	_station_panel.custom_minimum_size = Vector2(rx + grid_w + 12, 124 + 4 * 60 + 16)
	_station_panel.size = _station_panel.custom_minimum_size
	_station_panel.visible = false
	layer.add_child(_station_panel)

	_station_title = Label.new()
	_station_title.position = Vector2(14, 8)
	_station_panel.add_child(_station_title)

	# --- left column: blueprints / actions -----------------------------------
	_left_header = Label.new()
	_left_header.modulate = Color(1, 1, 1, 0.7)
	_left_header.position = Vector2(14, 36)
	_station_panel.add_child(_left_header)

	_refine_btn = Button.new()
	_refine_btn.text = "Refine"
	_refine_btn.position = Vector2(12, 62)
	_refine_btn.custom_minimum_size = Vector2(_LEFT_W, 30)
	_refine_btn.pressed.connect(_on_refine)
	_station_panel.add_child(_refine_btn)

	# per-station craft buttons are (re)built when the station opens
	_craft_row = Control.new()
	_craft_row.position = Vector2(12, 62)
	_station_panel.add_child(_craft_row)

	_preview_label = Label.new()
	_preview_label.position = Vector2(14, 210)
	_preview_label.custom_minimum_size = Vector2(_LEFT_W, 0)
	_preview_label.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
	_preview_label.modulate = Color(0.82, 0.92, 1.0)
	_station_panel.add_child(_preview_label)

	# --- right column: machine storage (top) + your inventory (bottom) -------
	_station_store_label = Label.new()
	_station_store_label.modulate = Color(1, 1, 1, 0.7)
	_station_store_label.position = Vector2(rx + 2, 36)
	_station_panel.add_child(_station_store_label)

	# storage cells are built dynamically on open (a chest group spans several blocks)
	_stor_container = Control.new()
	_stor_container.position = Vector2(rx, 60)
	_station_panel.add_child(_stor_container)

	_pinv_label = Label.new()
	_pinv_label.text = "Your inventory  (drag to move)"
	_pinv_label.modulate = Color(1, 1, 1, 0.7)
	_pinv_label.position = Vector2(rx + 2, 122)
	_station_panel.add_child(_pinv_label)

	_pinv_grid = GridContainer.new()
	_pinv_grid.columns = HOTBAR_SLOTS
	_pinv_grid.add_theme_constant_override("h_separation", 4)
	_pinv_grid.add_theme_constant_override("v_separation", 4)
	_pinv_grid.position = Vector2(rx, 146)
	_station_panel.add_child(_pinv_grid)
	for i in SLOTS:
		_pinv_cells.append(_make_slot(_pinv_grid, i, "to_station"))


func _looked_at_station() -> Station:
	_ray.force_raycast_update()
	if not _ray.is_colliding():
		return null
	var c := _ray.get_collider()
	return c as Station if c is Station else null


func _open_station(st: Station) -> void:
	_station_open = st
	if inv_open:
		_toggle_inventory()
	_station_title.text = st.title()
	_station_store_label.text = "%s contents  (drag to move)" % st.title()
	var is_smelter: bool = st.kind == Blocks.SMELTER
	_refine_btn.visible = is_smelter

	# rebuild this station's craft buttons as a vertical list in the left column
	for b in _craft_buttons:
		b.queue_free()
	_craft_buttons.clear()
	var crafts: Array = Blocks.STATION_CRAFTS.get(st.kind, [])
	var by := 0.0
	for craft in crafts:
		var b := Button.new()
		b.text = craft["label"]
		b.position = Vector2(0, by)
		b.custom_minimum_size = Vector2(_LEFT_W, 30)
		b.pressed.connect(_on_station_craft.bind(craft))
		_craft_row.add_child(b)
		_craft_buttons.append(b)
		by += 34.0
	_preview_label.visible = not crafts.is_empty()
	var has_left: bool = is_smelter or not crafts.is_empty()
	_left_header.visible = has_left
	_left_header.text = "Actions" if is_smelter else "Blueprints"

	# build the storage grid (a chest opens its whole connected group) and reflow
	var ext := _build_storage_cells(st)   # (cols, rows) in cells
	var store_bottom: int = 60 + ext.y * 60
	_pinv_label.position = Vector2(_rx + 2, store_bottom + 4)
	_pinv_grid.position = Vector2(_rx, store_bottom + 28)
	var store_w: int = maxi(ext.x, _STORE_COLS) * 60
	var w: int = _rx + store_w + 12
	var h: int = maxi(store_bottom + 28 + 4 * 60 + 16, 250)
	_station_panel.custom_minimum_size = Vector2(w, h)
	_station_panel.size = Vector2(w, h)
	var vp := get_viewport().get_visible_rect().size
	_station_panel.position = ((vp - Vector2(w, h)) * 0.5).round()

	_station_panel.visible = true
	Input.mouse_mode = Input.MOUSE_MODE_VISIBLE
	_refresh_station_ui()


func _close_station() -> void:
	_station_open = null
	if _station_panel != null:
		_station_panel.visible = false
	Input.mouse_mode = Input.MOUSE_MODE_CAPTURED


# --- storage layout (chests connect into one shared grid) ---------------------

# (Re)build the storage cells for the open station, returning the grid size in
# cells (cols, rows). A chest lays out its whole connected group; other machines
# are a single 8-wide block.
func _build_storage_cells(st: Station) -> Vector2i:
	for c in _station_cells:
		c["root"].queue_free()
	_station_cells.clear()
	_stor_map.clear()
	var maxc := 0
	var maxr := 0
	for pl in _storage_placements(st):
		var idx := _stor_map.size()
		_station_cells.append(_make_stor_cell(idx, pl["cx"], pl["cy"]))
		_stor_map.append({"st": pl["st"], "slot": pl["slot"]})
		maxc = maxi(maxc, int(pl["cx"]) + 1)
		maxr = maxi(maxr, int(pl["cy"]) + 1)
	return Vector2i(maxc, maxr)


# Where each (station, slot) sits in the combined grid: {st, slot, cx, cy}.
func _storage_placements(st: Station) -> Array:
	var out := []
	if st.kind == Blocks.CHEST:
		for blk in _chest_layout(st):
			var cst: Station = blk["st"]
			for slot in cst.storage.size():
				out.append({"st": cst, "slot": slot,
					"cx": int(blk["cb"]) * _STORE_COLS + slot % _STORE_COLS,
					"cy": int(blk["rb"]) * 3 + slot / _STORE_COLS})
	else:
		for slot in st.storage.size():
			out.append({"st": st, "slot": slot, "cx": slot % _STORE_COLS, "cy": slot / _STORE_COLS})
	return out


func _make_stor_cell(index: int, cx: int, cy: int) -> Dictionary:
	var root := Panel.new()
	root.custom_minimum_size = Vector2(56, 56)
	root.size = Vector2(56, 56)
	root.position = Vector2(cx * 60, cy * 60)
	_stor_container.add_child(root)
	var swatch := ColorRect.new()
	swatch.position = Vector2(6, 6)
	swatch.size = Vector2(44, 44)
	swatch.mouse_filter = Control.MOUSE_FILTER_IGNORE
	root.add_child(swatch)
	var count := Label.new()
	count.position = Vector2(28, 34)
	count.mouse_filter = Control.MOUSE_FILTER_IGNORE
	root.add_child(count)
	root.set_drag_forwarding(
		_slot_get_drag.bind("stor", index, root),
		_slot_can_drop.bind("stor", index),
		_slot_do_drop.bind("stor", index))
	return {"root": root, "swatch": swatch, "count": count}


const MAX_CHEST_GROUP := 4   # chests won't combine into a cluster bigger than this
const _NEIGH6 := [Vector3i(1, 0, 0), Vector3i(-1, 0, 0), Vector3i(0, 1, 0),
	Vector3i(0, -1, 0), Vector3i(0, 0, 1), Vector3i(0, 0, -1)]


func _chest_posmap(parent: Node) -> Dictionary:
	var m := {}
	if world != null:
		for s in world._stations:
			if is_instance_valid(s) and s.kind == Blocks.CHEST and s.get_parent() == parent:
				m[Vector3i(s.position.round())] = s
	return m


# All chests connected (face-adjacent, same frame) to `chest`.
func _chest_group(chest: Station) -> Array:
	var posmap := _chest_posmap(chest.get_parent())
	var seen := {}
	var stack := [Vector3i(chest.position.round())]
	var group := []
	while not stack.is_empty():
		var p: Vector3i = stack.pop_back()
		if seen.has(p):
			continue
		seen[p] = true
		if not posmap.has(p):
			continue
		group.append(posmap[p])
		for n in _NEIGH6:
			if not seen.has(p + n):
				stack.append(p + n)
	return group


# Size of the chest cluster that would form if a chest were placed at `cell` in
# `parent`'s frame (existing connected chests + the new one).
func _chest_cluster_size_at(parent: Node, cell: Vector3i) -> int:
	var posmap := _chest_posmap(parent)
	var seen := {}
	var stack := []
	for n in _NEIGH6:
		if posmap.has(cell + n):
			stack.append(cell + n)
	var count := 0
	while not stack.is_empty():
		var p: Vector3i = stack.pop_back()
		if seen.has(p):
			continue
		seen[p] = true
		if not posmap.has(p):
			continue
		count += 1
		for n in _NEIGH6:
			if not seen.has(p + n):
				stack.append(p + n)
	return count + 1


# The chest's local up axis (snapped) -- stacking along it grows the grid taller;
# spreading perpendicular to it grows the grid wider.
func _chest_up_axis(c: Station) -> Vector3i:
	var y := c.transform.basis.y
	var ax := absf(y.x)
	var ay := absf(y.y)
	var az := absf(y.z)
	if ax >= ay and ax >= az:
		return Vector3i(1 if y.x >= 0.0 else -1, 0, 0)
	if ay >= az:
		return Vector3i(0, 1 if y.y >= 0.0 else -1, 0)
	return Vector3i(0, 0, 1 if y.z >= 0.0 else -1)


func _horiz_key(c: Station, up: Vector3i) -> Vector2i:
	var p := Vector3i(c.position.round())
	if absi(up.y) == 1:
		return Vector2i(p.x, p.z)
	if absi(up.x) == 1:
		return Vector2i(p.y, p.z)
	return Vector2i(p.x, p.y)


func _horiz_less(a: Station, b: Station, up: Vector3i) -> bool:
	var ka := _horiz_key(a, up)
	var kb := _horiz_key(b, up)
	return ka.x < kb.x if ka.x != kb.x else ka.y < kb.y


# Assign each chest in the group a (col-block, row-block): rows = vertical levels
# (higher chests on top), columns = ordering within a level.
func _chest_layout(chest: Station) -> Array:
	var group := _chest_group(chest)
	if group.size() <= 1:
		return [{"st": chest, "cb": 0, "rb": 0}]
	var up := _chest_up_axis(chest)
	var levels := {}
	for c in group:
		var d := Vector3i(c.position.round())
		var v: int = d.x * up.x + d.y * up.y + d.z * up.z
		if not levels.has(v):
			levels[v] = []
		levels[v].append(c)
	var keys := levels.keys()
	keys.sort()
	keys.reverse()   # higher vertical level = top row
	var out := []
	var rb := 0
	for k in keys:
		var band: Array = levels[k]
		band.sort_custom(_horiz_less.bind(up))
		var cb := 0
		for c in band:
			out.append({"st": c, "cb": cb, "rb": rb})
			cb += 1
		rb += 1
	return out


func _refresh_station_ui() -> void:
	if _station_open == null:
		return
	for i in _station_cells.size():
		_paint_cell(_station_cells[i], _slot_ref("stor", i), false)
	for i in _pinv_cells.size():
		_paint_cell(_pinv_cells[i], inv[i], false)
	if Blocks.STATION_CRAFTS.has(_station_open.kind):
		_preview_label.text = _craft_preview_text(_station_open.kind)


func _on_refine() -> void:
	if _station_open == null:
		return
	var n := _station_open.refine_all()
	_toast("Refined %d material%s" % [n, "" if n == 1 else "s"] if n > 0 else "Add raw ore to refine")
	_refresh_station_ui()
	_refresh_slots()


# The refined material a station will build from (first refined slot loaded).
func _station_primary_material() -> Dictionary:
	if _station_open == null:
		return {}
	for s in _station_open.storage:
		if s["count"] > 0 and Blocks.is_refined(s["id"]):
			return s
	return {}


func _craft_preview_text(kind: int) -> String:
	var m := _station_primary_material()
	if m.is_empty():
		return "Load a refined material to build from →"
	var p: Dictionary = m["props"]
	var s := "%s   H%d D%d E%d R%d" % [m["mat"].get("name", "material"),
		int(p.get("h", 0)), int(p.get("d", 0)), int(p.get("e", 0)), int(p.get("r", 0))]
	if kind == Blocks.FABRICATOR:
		var power := Blocks.drill_power(p)
		s += "\nDrill: power %.1f — up to Tier %d" % [power, Blocks.max_tier_for_power(power)]
	elif kind == Blocks.SHIPWORKS:
		s += "\nThruster thrust ↑ with Energy   |   Hull mass ↑ with Density"
	return s


func _on_station_craft(craft: Dictionary) -> void:
	var m := _station_primary_material()
	if m.is_empty():
		_toast("Load a refined material")
		return
	var cost: int = craft["cost"]
	if m["count"] < cost:
		_toast("Need %d refined material" % cost)
		return
	var out: int = craft["out"]
	var n: int = craft.get("n", 1)
	var mname: String = m["mat"].get("name", "")
	m["count"] -= cost
	if m["count"] <= 0:
		m["id"] = Blocks.AIR
	# the crafted item carries the material's identity + props (thrust/mass/etc.
	# are derived from these); the drill also stores its computed power
	var cmat := {"name": mname, "color": m["mat"].get("color", Color(0.75, 0.76, 0.8)),
		"tier": m["mat"].get("tier", 0)}
	if out == Blocks.DRILL:
		cmat["power"] = Blocks.drill_power(m["props"])
	var left := _station_open.store_add(out, n, m["props"], m.get("src", ""), cmat)
	if left > 0:
		_toast("No room in the machine")
	else:
		_toast("Crafted %s %s" % [mname, Blocks.name_of(out)])
	_refresh_station_ui()
	_refresh_slots()


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
	var tool_txt := "Drill (power %.1f, T%d)" % [mine_power, Blocks.max_tier_for_power(mine_power)] if mine_power > 1.0 else "bare hands"
	_hotbar_label.text = "Holding: %s   |   Mining: %s" % [
		(Blocks.name_of(held) if held != Blocks.AIR else "(empty slot)"), tool_txt]
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
