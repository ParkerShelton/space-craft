class_name ShipWake
extends Node3D
## The ship coming back to life, one system at a time.
##
## The computer's checklist says what is fixed. This is the ship SHOWING it,
## so a repair is something that happens rather than a row that turns green:
##
##   No power: the cabin lamp is dark and a red emergency light breathes in
##   the roof. Seat a charged battery and the relay clunks, the bus hums up,
##   and the lamp stutters on.
##
##   Life support that has power and a sealed room starts breathing -- a valve
##   knocks and air comes through the vents -- and says so again when the
##   cabin is full.
##
##   Every thruster bolted on is test-fired: a burst of flame out of the
##   nozzle. One fitted while she is dark waits, and fires when the power
##   comes back.
##
##   The moment nothing is left on the list, the computer chimes and says so
##   across the whole screen. She will fly.
##
## It also draws the engine flames while she is spooling up and flying (the
## spool itself is Ship._spool_up), and reveals the crash site on the HUD the
## first time she leaves the ground.
##
## What she was already like when this starts watching -- a world just loaded,
## a wreck just placed -- is taken as given, silently. Only CHANGES are shown.
##
## SELF-CONTAINED: this file, plus the lines in WorldManager that add one to
## every ship. Delete both and nothing else changes.

const POLL := 0.2              # seconds between looks at her systems
## How long after it starts watching that everything is taken as given. A wreck
## is placed with her charge at nothing and the battery rack pours into it over
## the next second or two; that is how she landed, not power being restored.
const SETTLE := 2.5
const NEAR := 40.0             # say things only to someone this close
const FLICKER := [0.0, 0.09, 0.16, 0.34, 0.41, 0.46, 0.72, 0.8, 1.15]  # on/off edges
const EMERGENCY := Color(1.0, 0.13, 0.08)
const FLAME := Color(1.0, 0.55, 0.18)

var ship: Ship
var _player: Node3D
var _world: WorldManager

var _light: OmniLight3D
var _banner: CanvasLayer
var _t := 0.0
var _poll := 0.0
var _known := false            # have we taken our first look yet?
var _powered := false
var _breathing := false
var _full := false
var _worthy := false
var _thrusters := {}           # cells we have seen fitted
var _to_test: Array = []       # cells waiting for a test burn
var _test_t := 0.0
var _flicker_t := -1.0         # >= 0 while the lamp is stuttering on
var _flames := {}              # thruster cell -> its flame node
var _last_air := 0.0


func setup(for_ship: Ship, player: Node3D, world: WorldManager) -> void:
	ship = for_ship
	_player = player
	_world = world
	if not ship.lifted_off.is_connected(_on_lifted_off):
		ship.lifted_off.connect(_on_lifted_off)


func _ready() -> void:
	_light = OmniLight3D.new()
	_light.light_color = EMERGENCY
	_light.omni_range = 6.5
	_light.light_energy = 0.0
	_light.shadow_enabled = false
	add_child(_light)


func _process(delta: float) -> void:
	if ship == null or not is_instance_valid(ship):
		return
	_t += delta
	_poll -= delta
	if _poll <= 0.0:
		_poll = POLL
		_look()
	_update_light(delta)
	_update_tests(delta)
	_update_flames(delta)


# --- watching ----------------------------------------------------------------

## One look at every system, acting on whatever has changed since the last.
func _look() -> void:
	var powered: bool = ship.charge > 0.0
	var st: Dictionary = ship.get_status()
	var breathing: bool = powered and bool(st.get("life_support", false)) \
		and bool(st.get("sealed", false)) and ship.air > _last_air + 0.0001
	var full: bool = ship.air >= 0.995 and bool(st.get("habitable", false))
	var worthy: bool = _is_worthy()
	var thr := {}
	for v in ship.blocks:
		if int(ship.blocks[v]) == Blocks.THRUSTER:
			thr[v] = true
	_last_air = ship.air
	_light.position = _cabin_light_at()
	if not _known or _t < SETTLE:
		# First looks: this is how she IS, not something that just happened.
		_known = true
		_powered = powered
		_breathing = breathing
		_full = full
		_worthy = worthy
		_thrusters = thr
		ship.set_lamp_power(1.0 if powered else 0.0)
		return
	if powered and not _powered:
		_power_on()
	elif not powered and _powered:
		_power_off()
	_powered = powered
	for v in thr:
		if not _thrusters.has(v):
			_to_test.append(v)
	_thrusters = thr
	if breathing and not _breathing:
		Audio.at("ship_air", ship.to_global(_cabin_light_at()))
		_say("Life support running -- the cabin is filling with air")
	_breathing = breathing
	if full and not _full:
		_say("Cabin pressurised")
	_full = full
	if worthy and not _worthy:
		_nominal()
	_worthy = worthy


## "Nothing left on the list" -- the computer's own verdict, for a ship that
## has one. A ship somebody built from scratch has no wreck to repair, and the
## moment it becomes flyable is the same moment.
func _is_worthy() -> bool:
	if ship.wreck_missing.is_empty() and ship.cabin_cells.is_empty():
		return bool(ship.get_status().get("can_fly", false)) and ship.charge > 0.0
	return ShipComputer.flightworthy(ship)


func _power_on() -> void:
	_flicker_t = 0.0
	Audio.at("ship_power_on", ship.to_global(_cabin_light_at()))
	_say("Power restored")


func _power_off() -> void:
	_flicker_t = -1.0
	ship.set_lamp_power(0.0)
	_say("Power lost -- emergency lighting only")


func _nominal() -> void:
	Audio.at("ship_nominal", ship.to_global(_cabin_light_at()))
	ship.ship_log.append("All systems nominal.")
	if _near():
		_show_banner("ALL SYSTEMS NOMINAL", "She will fly. Take the pilot's seat.")


func _on_lifted_off(first: bool) -> void:
	if not first or _world == null:
		return
	ship.ship_log.append("Off the ground.")
	# The place it all started goes on the map now that you are leaving it.
	if not _world.crash_site.is_empty():
		_world.crash_site["shown"] = true


# --- the cabin light -----------------------------------------------------------

## Under her lamp if she has one, otherwise the middle of her.
func _cabin_light_at() -> Vector3:
	for v in ship.blocks:
		if int(ship.blocks[v]) == Blocks.GLOW_LAMP:
			return Vector3(v as Vector3i) + Vector3(0.5, 0.1, 0.5)
	return ship.center_local() + Vector3(0.5, 0.5, 0.5)


func _update_light(delta: float) -> void:
	if _flicker_t >= 0.0:
		# Stuttering on: the lamp and the emergency light trade places on a
		# fixed rhythm of edges, and the lamp wins at the end.
		_flicker_t += delta
		var edges := 0
		for e in FLICKER:
			if _flicker_t >= float(e):
				edges += 1
		var on: bool = edges % 2 == 1
		ship.set_lamp_power(1.0 if on else 0.08)
		_light.light_energy = 0.0 if on else 0.6
		if _flicker_t > float(FLICKER[FLICKER.size() - 1]) + 0.05:
			_flicker_t = -1.0
			ship.set_lamp_power(1.0)
			_light.light_energy = 0.0
		return
	if _powered or not _known:
		_light.light_energy = 0.0
		return
	# Dark: a slow red breath, the only light she has left.
	var breath: float = 0.5 + 0.5 * sin(_t * 2.2)
	_light.light_color = EMERGENCY
	_light.light_energy = lerpf(0.5, 2.0, breath * breath)


# --- engines -------------------------------------------------------------------

## Fire the next thruster waiting for a test, once she has power to do it with.
func _update_tests(delta: float) -> void:
	_test_t -= delta
	if _to_test.is_empty() or _test_t > 0.0 or not _powered or _flicker_t >= 0.0:
		return
	var v: Vector3i = _to_test.pop_front()
	if int(ship.blocks.get(v, Blocks.AIR)) != Blocks.THRUSTER:
		return
	_test_t = 0.7
	_burst(v)
	if _near():
		_say("Engine test: firing")


## A short test burn out of one nozzle: the flame opens, holds, and dies.
func _burst(v: Vector3i) -> void:
	var f := _flame_node()
	f.position = _nozzle(v)
	add_child(f)
	Audio.at("ship_burn", ship.to_global(f.position))
	var tw := create_tween()
	tw.tween_method(_set_flame.bind(f), 0.0, 1.0, 0.12)
	tw.tween_method(_set_flame.bind(f), 1.0, 0.85, 0.45)
	tw.tween_method(_set_flame.bind(f), 0.85, 0.0, 0.35)
	tw.tween_callback(f.queue_free)


## Steady flames out of every nozzle while she is burning (spool, liftoff,
## flight), scaled by how hard.
func _update_flames(_delta: float) -> void:
	var g: float = ship.engine_glow if ship.flying else 0.0
	for v in _thrusters:
		var f: Node3D = _flames.get(v)
		if g <= 0.01:
			if f != null:
				f.visible = false
			continue
		if f == null or not is_instance_valid(f):
			f = _flame_node()
			add_child(f)
			_flames[v] = f
		f.position = _nozzle(v as Vector3i)
		f.visible = true
		# A little unsteady, the way a flame is.
		_set_flame(g * (0.9 + 0.1 * sin(_t * 31.0 + float(v.x) * 7.0)), f)
	for v2 in _flames.keys():
		if not _thrusters.has(v2):
			(_flames[v2] as Node3D).queue_free()
			_flames.erase(v2)


## The back of a thruster's cell, where the exhaust comes out: engines face
## the tail (+Z), since -Z is the nose.
func _nozzle(v: Vector3i) -> Vector3:
	return Vector3(v) + Vector3(0.5, 0.5, 1.02)


## A flame: a cone of light pointing aft, and a light of its own so it throws
## colour on the ground under her.
func _flame_node() -> Node3D:
	var root := Node3D.new()
	var cone := MeshInstance3D.new()
	var cm := CylinderMesh.new()
	cm.top_radius = 0.02
	cm.bottom_radius = 0.3
	cm.height = 1.0
	cm.radial_segments = 10
	cm.rings = 1
	cone.mesh = cm
	var mat := StandardMaterial3D.new()
	mat.shading_mode = BaseMaterial3D.SHADING_MODE_UNSHADED
	mat.transparency = BaseMaterial3D.TRANSPARENCY_ALPHA
	mat.blend_mode = BaseMaterial3D.BLEND_MODE_ADD
	mat.albedo_color = Color(FLAME.r, FLAME.g, FLAME.b, 0.9)
	mat.cull_mode = BaseMaterial3D.CULL_DISABLED
	cone.material_override = mat
	cone.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
	# The cylinder stands along Y; tip it to point aft, wide end at the nozzle.
	cone.rotation.x = PI * 0.5
	cone.name = "Cone"
	root.add_child(cone)
	var lt := OmniLight3D.new()
	lt.light_color = FLAME
	lt.omni_range = 4.0
	lt.name = "Glow"
	root.add_child(lt)
	return root


## How much flame, 0..1: the cone's length and the light's strength.
func _set_flame(k: float, f: Node3D) -> void:
	if f == null or not is_instance_valid(f):
		return
	var cone := f.get_node_or_null("Cone") as MeshInstance3D
	var lt := f.get_node_or_null("Glow") as OmniLight3D
	var ln: float = maxf(k, 0.001) * 1.6
	if cone != null:
		cone.scale = Vector3(0.6 + 0.4 * k, ln, 0.6 + 0.4 * k)
		cone.position = Vector3(0, 0, ln * 0.5)
	if lt != null:
		lt.light_energy = 2.2 * k


# --- telling you ---------------------------------------------------------------

func _near() -> bool:
	return _player != null and is_instance_valid(_player) \
		and _player.global_position.distance_to(ship.global_position) < NEAR


func _say(msg: String) -> void:
	if _near() and _player.has_method("notify"):
		_player.call("notify", msg)


## Big, centred, and gone on its own: the one thing in the opening that is
## allowed to take the whole screen for a moment.
func _show_banner(title: String, sub: String) -> void:
	if _banner != null and is_instance_valid(_banner):
		_banner.queue_free()
	_banner = CanvasLayer.new()
	_banner.layer = 50
	add_child(_banner)
	var box := VBoxContainer.new()
	box.set_anchors_preset(Control.PRESET_CENTER)
	box.grow_horizontal = Control.GROW_DIRECTION_BOTH
	box.grow_vertical = Control.GROW_DIRECTION_BOTH
	box.alignment = BoxContainer.ALIGNMENT_CENTER
	box.mouse_filter = Control.MOUSE_FILTER_IGNORE
	box.position.y = -90
	_banner.add_child(box)
	var head := Label.new()
	head.text = title
	head.add_theme_font_size_override("font_size", 46)
	head.add_theme_color_override("font_color", Color(0.62, 1.0, 0.72))
	head.add_theme_color_override("font_outline_color", Color(0, 0, 0, 0.85))
	head.add_theme_constant_override("outline_size", 8)
	head.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	box.add_child(head)
	var line := Label.new()
	line.text = sub
	line.add_theme_font_size_override("font_size", 20)
	line.add_theme_color_override("font_outline_color", Color(0, 0, 0, 0.85))
	line.add_theme_constant_override("outline_size", 6)
	line.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	box.add_child(line)
	box.modulate.a = 0.0
	var tw := create_tween()
	tw.tween_property(box, "modulate:a", 1.0, 0.5)
	tw.tween_interval(3.2)
	tw.tween_property(box, "modulate:a", 0.0, 1.0)
	tw.tween_callback(_banner.queue_free)
