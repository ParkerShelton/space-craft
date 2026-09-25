class_name RepairGhosts
extends Node3D
## What the ship is missing, drawn where it is missing from.
##
## The wreck already knows every piece that came off it -- `Ship.wreck_missing`
## maps each torn-out cell to the exact block that used to be there -- and until
## now the only thing that read it was the computer, which turned it into a
## sentence. This draws it instead.
##
## Two kinds of thing, because they are two different questions:
##
##   A hole in the hull is a WHERE question. It gets a pale blue block standing
##   in the gap it belongs in. Put a real plate there and the ghost goes.
##
##   A missing part is a WHAT question. It gets a hologram of the part itself,
##   turning slowly above the mount it belongs on, with the one line that says
##   how to get one. Where it is hovering answers the where; what it looks like
##   answers the what.
##
## Nothing here says "press" anything and nothing appears on the HUD. It is the
## ship showing you what it needs, which is the same restraint the computer and
## the journal keep.
##
## SELF-CONTAINED and deletable: this file, plus the two lines in main.gd that
## mention RepairGhosts.

## Only drawn when you are near enough for it to be about the ship in front of
## you rather than a light show on the horizon.
const SHOW_RANGE := 34.0
const FADE_RANGE := 42.0
const BLUE := Color(0.32, 0.72, 1.0)
## How often the missing list is re-read. It is a dictionary lookup over a
## handful of cells; every frame would be waste, and half a second is faster
## than anyone can place a block and look up.
const RECHECK := 0.4

var ship: Ship
var _player: Node3D
var _holes: MeshInstance3D
var _parts: Node3D
var _sig := ""
var _t := 0.0
var _check_t := 0.0


func setup(for_ship: Ship, player: Node3D) -> void:
	ship = for_ship
	_player = player


func _ready() -> void:
	_holes = MeshInstance3D.new()
	_holes.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
	add_child(_holes)
	_parts = Node3D.new()
	add_child(_parts)


func _process(delta: float) -> void:
	if ship == null or not is_instance_valid(ship) or _player == null:
		visible = false
		return
	_t += delta
	var d: float = _player.global_position.distance_to(ship.global_position)
	var near: bool = d < FADE_RANGE
	visible = near
	if not near:
		return
	# Once she flies there is nothing left to point at.
	if ShipComputer.flightworthy(ship):
		visible = false
		return
	_check_t -= delta
	if _check_t <= 0.0:
		_check_t = RECHECK
		var sig := _signature()
		if sig != _sig:
			_sig = sig
			_rebuild()
	# A slow breath, so it reads as something being projected rather than
	# something built out of glass.
	var pulse: float = 0.5 + 0.5 * sin(_t * 1.8)
	var fade: float = clampf((FADE_RANGE - d) / (FADE_RANGE - SHOW_RANGE), 0.0, 1.0)
	if _holes.material_override is StandardMaterial3D:
		var m := _holes.material_override as StandardMaterial3D
		m.albedo_color = Color(BLUE.r, BLUE.g, BLUE.b, lerpf(0.16, 0.34, pulse) * fade)
	for c in _parts.get_children():
		var h := c as Node3D
		if h == null:
			continue
		# Turning, the way a thing being shown to you turns.
		h.rotation.y = _t * 0.9
		h.position.y = h.get_meta("base_y", 0.0) + sin(_t * 1.4) * 0.09


## What is missing, as one string, so the ghosts are only rebuilt when the
## answer changes rather than every time they are looked at.
func _signature() -> String:
	var parts: Array = []
	for v in _hole_cells():
		parts.append(str(v))
	for it in ShipComputer.checklist(ship):
		var item: ShipComputer.Item = it
		if not item.done:
			parts.append(item.name)
	return "|".join(PackedStringArray(parts))


## The cells you have to fill with plate: holes in the cabin shell, and nothing
## else. A wing that came off is not something you rebuild -- it is scrap on
## the ground -- and ghosting it would say the opposite.
func _hole_cells() -> Array:
	var shell := {}
	for c in ship.cabin_cells:
		shell[c] = true
	var out: Array = []
	for v in ship.wreck_missing:
		if not shell.has(v):
			continue
		if Blocks.is_door(int(ship.wreck_missing[v])):
			continue   # the doorway gets a hologram of a door, not a plate
		if ship.blocks.has(v):
			continue   # already filled
		out.append(v)
	out.sort()
	return out


func _rebuild() -> void:
	_holes.mesh = _hole_mesh(_hole_cells())
	if _holes.material_override == null:
		_holes.material_override = _ghost_material()
	for c in _parts.get_children():
		c.queue_free()
	for spec in _missing_parts():
		_add_part(spec)


## A block standing in each gap, drawn a little inside the cell so two ghosts
## side by side still read as two.
func _hole_mesh(cells: Array) -> ArrayMesh:
	if cells.is_empty():
		return null
	var st := SurfaceTool.new()
	st.begin(Mesh.PRIMITIVE_TRIANGLES)
	const INSET := 0.06
	for v in cells:
		var lo: Vector3 = Vector3(v as Vector3i) + Vector3.ONE * INSET
		var hi: Vector3 = Vector3(v as Vector3i) + Vector3.ONE * (1.0 - INSET)
		for fi in 6:
			st.set_color(Color(1, 1, 1, 1))
			st.set_normal(Vector3(Chunk._WFACE[fi]))
			var q := Chunk._box_face(lo, hi, fi)
			st.add_vertex(q[0]); st.add_vertex(q[2]); st.add_vertex(q[1])
			st.add_vertex(q[0]); st.add_vertex(q[3]); st.add_vertex(q[2])
	return st.commit()


func _ghost_material() -> StandardMaterial3D:
	var m := StandardMaterial3D.new()
	m.transparency = BaseMaterial3D.TRANSPARENCY_ALPHA
	m.shading_mode = BaseMaterial3D.SHADING_MODE_UNSHADED
	m.cull_mode = BaseMaterial3D.CULL_DISABLED
	m.albedo_color = Color(BLUE.r, BLUE.g, BLUE.b, 0.25)
	# Drawn over whatever is in front of it. A hologram you cannot see through
	# the hull is a hologram you have to go and look for.
	m.no_depth_test = true
	m.render_priority = 2
	return m


## Each part that is still missing: what it looks like, where it belongs, and
## the one line that says how to get one.
func _missing_parts() -> Array:
	var out: Array = []
	var st: Dictionary = ship.get_status()
	# The door, if the doorway is empty.
	var door_gone := false
	for v in ship.wreck_missing:
		if Blocks.is_door(int(ship.wreck_missing[v])) and not ship.blocks.has(v):
			door_gone = true
	if door_gone:
		out.append({"at": Vector3(CrashSite.DOOR_AT) + Vector3(0.5, 1.6, 0.5),
			"mesh": _boxes_mesh(Chunk.shape_boxes(
				Blocks.door_with(false, 0, 0, false), Vector3.UP)),
			"scale": 1.0, "text": "Door\nCarpenter's Bench"})
	if not bool(st.get("life_support", false)):
		out.append({"at": Vector3(CrashSite.LIFE_SUPPORT_AT) + Vector3(0.5, 1.7, 0.5),
			"mesh": Ship._fitting_mesh(Blocks.LIFE_SUPPORT),
			"scale": 0.9, "text": "Life Support\nShipworks, or salvage one"})
	var thrusters := int(st.get("thrusters", 0))
	if thrusters < 2:
		for side in [-1, 1]:
			var cell := CrashSite.thruster_at(side)
			if ship.blocks.has(cell):
				continue
			out.append({"at": Vector3(cell) + Vector3(0.5, 1.7, 0.5),
				"mesh": Ship._fitting_mesh(Blocks.THRUSTER),
				"scale": 0.9, "text": "Thruster\nShipworks, or salvage one"})
	# Power: either there is no rack, or nothing charged in it.
	var bay := ShipComputer.power_bay(ship)
	if bay == null:
		out.append({"at": Vector3(CrashSite.POWER_BAY_AT) + Vector3(0.5, 1.7, 0.5),
			"mesh": StationModels.mesh_from_boxes(
				StationModels.power_bay_boxes(false, 0.0)),
			"scale": 0.8, "text": "Power Bay\nShipworks"})
	elif ShipComputer.battery_charge(bay) <= 0.0:
		out.append({"at": Vector3(CrashSite.POWER_BAY_AT) + Vector3(0.5, 1.9, 0.5),
			"mesh": StationModels.battery_icon_mesh(),
			"scale": 1.3, "text": "Battery, charged\nFill one at a Generator"})
	return out


func _add_part(spec: Dictionary) -> void:
	var holder := Node3D.new()
	holder.position = spec["at"] as Vector3
	holder.set_meta("base_y", holder.position.y)
	_parts.add_child(holder)
	var mi := MeshInstance3D.new()
	mi.mesh = spec["mesh"]
	mi.scale = Vector3.ONE * float(spec.get("scale", 1.0))
	mi.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
	mi.material_override = _ghost_material()
	holder.add_child(mi)
	var label := Label3D.new()
	label.text = str(spec["text"])
	label.billboard = BaseMaterial3D.BILLBOARD_ENABLED
	label.no_depth_test = true
	label.render_priority = 3
	label.outline_render_priority = 2
	label.font_size = 48
	label.pixel_size = 0.006
	label.modulate = Color(BLUE.r, BLUE.g, BLUE.b, 0.95)
	label.outline_modulate = Color(0, 0, 0, 0.6)
	label.position = Vector3(0, 0.75, 0)
	# The text does NOT turn with the part: a label that spins is a label you
	# cannot read.
	label.set_as_top_level(true)
	label.global_position = holder.global_position + Vector3(0, 0.75, 0)
	holder.add_child(label)


## A box list to a plain mesh, for the shapes that come as boxes rather than as
## a finished model.
func _boxes_mesh(boxes: Array) -> ArrayMesh:
	var st := SurfaceTool.new()
	st.begin(Mesh.PRIMITIVE_TRIANGLES)
	for b in boxes:
		var lo: Vector3 = (b[0] as Vector3) - Vector3(0.5, 0.5, 0.5)
		var hi: Vector3 = (b[1] as Vector3) - Vector3(0.5, 0.5, 0.5)
		for fi in 6:
			st.set_color(Color(1, 1, 1, 1))
			st.set_normal(Vector3(Chunk._WFACE[fi]))
			var q := Chunk._box_face(lo, hi, fi)
			st.add_vertex(q[0]); st.add_vertex(q[2]); st.add_vertex(q[1])
			st.add_vertex(q[0]); st.add_vertex(q[3]); st.add_vertex(q[2])
	return st.commit()
