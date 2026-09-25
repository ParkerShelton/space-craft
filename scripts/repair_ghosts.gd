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
## Which checklist lines you have asked to SEE. Empty by default: the ship does
## not decorate itself unless you ask it to. Keyed by the checklist item's name,
## which is what the computer's rows are labelled with.
var shown := {}
var _sig := ""
var _t := 0.0
var _check_t := 0.0


## Turn one line's ghosts on or off. Called by the ship's computer when you
## click that row, and nothing else turns them on.
func toggle(item_name: String) -> bool:
	if shown.has(item_name):
		shown.erase(item_name)
	else:
		shown[item_name] = true
	_sig = ""        # force a rebuild on the next look
	_check_t = 0.0
	return shown.has(item_name)


func is_showing(item_name: String) -> bool:
	return shown.has(item_name)


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
	if ShipComputer.flightworthy(ship) or shown.is_empty():
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
		m.albedo_color = Color(BLUE.r, BLUE.g, BLUE.b, lerpf(0.34, 0.62, pulse) * fade)
	for c in _parts.get_children():
		var h := c as Node3D
		if h == null:
			continue
		if h.has_meta("is_label"):
			# Hidden once you are on top of it. A world-space label in a cabin
			# two blocks across is across your whole screen at arm's length,
			# and by then the hologram under it has already said what it is.
			h.visible = _player.global_position.distance_to(h.global_position) > 1.3
			continue
		if not h.has_meta("base_y"):
			continue
		# Turning, the way a thing being shown to you turns.
		h.rotation.y = _t * 0.9
		h.position.y = h.get_meta("base_y", 0.0) + sin(_t * 1.4) * 0.07


## What is missing, as one string, so the ghosts are only rebuilt when the
## answer changes rather than every time they are looked at.
func _signature() -> String:
	var parts: Array = []
	for k in shown:
		parts.append("+" + str(k))
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
	_holes.mesh = _hole_mesh(_hole_cells()) if shown.has("Hull sealed") else null
	if _holes.material_override == null:
		_holes.material_override = _ghost_material()
	for c in _parts.get_children():
		c.queue_free()
	for spec in _missing_parts():
		_add_part(spec)


## A blueprint outline standing in each gap: twelve thin bars along the edges
## of the cell, not a solid block.
##
## Solid was the obvious thing and it was wrong. Four holes in a cabin two
## blocks tall put a wall of bright blue across half the view, and a marker you
## cannot see past is worse than no marker. An outline says exactly the same
## thing -- this cell, this size, this shape -- and leaves the room visible.
func _hole_mesh(cells: Array) -> ArrayMesh:
	if cells.is_empty():
		return null
	var st := SurfaceTool.new()
	st.begin(Mesh.PRIMITIVE_TRIANGLES)
	const T := 0.055     # how thick a bar is
	const INSET := 0.04  # held off the cell edge so two side by side still read
	for v in cells:
		var o: Vector3 = Vector3(v as Vector3i) + Vector3.ONE * INSET
		var e: float = 1.0 - INSET * 2.0
		for axis in 3:
			for a in 2:
				for b in 2:
					var lo := o
					var hi := o
					# The bar runs the length of `axis` and is thin on the
					# other two, placed at one of that face's four corners.
					var other := 0
					for k in 3:
						if k == axis:
							lo[k] = o[k]
							hi[k] = o[k] + e
							continue
						var pick: int = a if other == 0 else b
						lo[k] = o[k] + (e - T) * float(pick)
						hi[k] = lo[k] + T
						other += 1
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
	m.albedo_color = Color(BLUE.r, BLUE.g, BLUE.b, 0.45)
	# Depth-tested like anything else. Drawing it over the world sounded good --
	# you could see what the far side needed without walking round -- but a
	# ghost you are standing next to then fills the entire screen, and half the
	# cabin is within arm's reach of a hole. The text still draws through, so
	# you can read a label from behind the thing it names.
	m.render_priority = 2
	return m


## Each part that is still missing. They sit ON their mount at half size rather
## than floating at head height: in a cabin two blocks tall, anything hovering
## where a person stands is something the camera ends up inside, and a hologram
## you are standing in the middle of is a blue screen.
##
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
	if door_gone and shown.has("Door"):
		out.append({"at": Vector3(CrashSite.DOOR_AT) + Vector3(0.5, 0.5, 0.5),
			"mesh": _boxes_mesh(Chunk.shape_boxes(
				Blocks.door_with(false, 0, 0, false), Vector3.UP)),
			"scale": 0.55, "pivot": Vector3.ZERO, "text": "Door\nCarpenter's Bench"})
	if not bool(st.get("life_support", false)) and shown.has("Life support"):
		out.append({"at": Vector3(CrashSite.LIFE_SUPPORT_AT) + Vector3(0.5, 0.5, 0.5),
			"mesh": Ship._fitting_mesh(Blocks.LIFE_SUPPORT),
			"scale": 0.5, "pivot": Vector3(-0.5, -0.5, -0.5), "text": "Life Support\nShipworks, or salvage one"})
	var thrusters := int(st.get("thrusters", 0))
	if thrusters < 2 and shown.has("Thrusters"):
		for side in [-1, 1]:
			var cell := CrashSite.thruster_at(side)
			if ship.blocks.has(cell):
				continue
			out.append({"at": Vector3(cell) + Vector3(0.5, 0.5, 0.5),
				"mesh": Ship._fitting_mesh(Blocks.THRUSTER),
				"scale": 0.5, "pivot": Vector3(-0.5, -0.5, -0.5), "text": "Thruster\nShipworks, or salvage one"})
	# Power: either there is no rack, or nothing charged in it.
	var bay := ShipComputer.power_bay(ship)
	if not shown.has("Power"):
		return out
	if bay == null:
		out.append({"at": Vector3(CrashSite.POWER_BAY_AT) + Vector3(0.5, 0.5, 0.5),
			"mesh": StationModels.mesh_from_boxes(
				StationModels.power_bay_boxes(false, 0.0)),
			"scale": 0.5, "pivot": Vector3(0, -0.4, 0), "text": "Power Bay\nShipworks"})
	elif ShipComputer.battery_charge(bay) <= 0.0:
		out.append({"at": Vector3(CrashSite.POWER_BAY_AT) + Vector3(0.5, 0.55, 0.5),
			"mesh": StationModels.battery_icon_mesh(),
			"scale": 0.8, "pivot": Vector3.ZERO, "text": "Battery, charged\nFill one at a Generator"})
	return out


func _add_part(spec: Dictionary) -> void:
	var holder := Node3D.new()
	holder.position = spec["at"] as Vector3
	holder.set_meta("base_y", holder.position.y)
	_parts.add_child(holder)
	var mi := MeshInstance3D.new()
	mi.mesh = spec["mesh"]
	var sc: float = float(spec.get("scale", 1.0))
	mi.scale = Vector3.ONE * sc
	# Shifted so the MODEL's middle sits on the holder, not its corner. A mesh
	# authored in cell space runs 0..1, so turning the holder swung it round the
	# corner of the cell and it orbited instead of spinning.
	mi.position = (spec.get("pivot", Vector3.ZERO) as Vector3) * sc
	mi.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
	mi.material_override = _ghost_material()
	holder.add_child(mi)
	# The text is a SIBLING of the turning part, not a child of it: a label that
	# spins with the thing it names is a label you cannot read. Being a sibling
	# also keeps it attached to the ship, which a top-level node would not.
	var label := Label3D.new()
	label.text = str(spec["text"])
	label.billboard = BaseMaterial3D.BILLBOARD_ENABLED
	label.no_depth_test = true
	label.render_priority = 3
	label.outline_render_priority = 2
	label.font_size = 40
	label.pixel_size = 0.0013
	label.modulate = Color(BLUE.r, BLUE.g, BLUE.b, 0.95)
	label.outline_modulate = Color(0, 0, 0, 0.7)
	label.outline_size = 10
	label.set_meta("is_label", true)
	_parts.add_child(label)
	label.position = (spec["at"] as Vector3) + Vector3(0, 0.4, 0)


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
