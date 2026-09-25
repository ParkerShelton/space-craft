class_name StationModels
extends RefCounted
## What each station looks like, and how much room it takes up.
##
## A station is a set model now rather than a shape you copy out of blocks, so
## this is the one place that says what one IS: how many blocks of ground it
## stands on, and the boxes it is built from. Boxes are given in BLOCKS, around
## the middle of the footprint at ground level -- y 0 is the floor it stands on,
## +Z is the way it faces.
##
## Footprints are whole blocks and may be more than one: a bench is two blocks
## long, a shipworks is a three by two shed.

## Blocks of ground each station stands on: x across, y up, z deep.
const FOOTPRINT := {
	Blocks.CAMPFIRE: Vector3i(1, 1, 1),
	Blocks.CARPENTER: Vector3i(2, 1, 1),
	Blocks.BED: Vector3i(1, 1, 2),
	Blocks.CHEST: Vector3i(1, 1, 1),
	Blocks.SHAPER: Vector3i(2, 1, 1),
	Blocks.SMELTER: Vector3i(1, 2, 1),
	Blocks.FORGE: Vector3i(2, 2, 1),
	Blocks.GENERATOR: Vector3i(1, 1, 1),
	Blocks.POWER_BAY: Vector3i(1, 1, 1),
	Blocks.OXYGEN_PLANT: Vector3i(1, 2, 1),
	Blocks.HEATER: Vector3i(1, 1, 1),
	Blocks.COOLER: Vector3i(1, 1, 1),
	Blocks.CLIMATE_UNIT: Vector3i(1, 2, 1),
	Blocks.FABRICATOR: Vector3i(2, 1, 1),
	Blocks.SHIPWORKS: Vector3i(3, 2, 2),
}

const WOOD := Color(0.48, 0.33, 0.18)
const DARK_WOOD := Color(0.34, 0.22, 0.12)
const STONE := Color(0.46, 0.46, 0.48)
const METAL := Color(0.60, 0.62, 0.66)
const DARK := Color(0.22, 0.23, 0.26)
const GLASS := Color(0.55, 0.75, 0.85, 0.5)
const EMBER := Color(1.0, 0.45, 0.12)
const GLOW := Color(0.45, 0.85, 1.0)
const CLOTH := Color(0.75, 0.3, 0.3)


static func footprint(kind: int) -> Vector3i:
	return FOOTPRINT.get(kind, Vector3i.ONE)


## The boxes a station is drawn from: [centre, size, colour], in blocks, with
## y 0 the ground it stands on. Anything glowing is listed in `glow_for`.
static func boxes_for(kind: int) -> Array:
	match kind:
		Blocks.CAMPFIRE:
			return [
				[Vector3(0, 0.07, 0), Vector3(0.85, 0.14, 0.85), Color(0.3, 0.3, 0.32)],
				[Vector3(-0.15, 0.2, 0.1), Vector3(0.6, 0.16, 0.16), DARK_WOOD],
				[Vector3(0.12, 0.2, -0.08), Vector3(0.16, 0.16, 0.6), DARK_WOOD],
				[Vector3(0, 0.3, 0), Vector3(0.4, 0.22, 0.4), EMBER]]
		Blocks.CARPENTER:
			var out: Array = []
			# Four legs of the same length, all standing on the floor.
			for sx in [-0.8, 0.8]:
				for sz in [-0.3, 0.3]:
					out.append([Vector3(sx, 0.31, sz), Vector3(0.16, 0.62, 0.16), DARK_WOOD])
			out.append([Vector3(0, 0.7, 0), Vector3(1.94, 0.16, 0.9), WOOD])
			out.append([Vector3(0, 0.82, 0.3), Vector3(1.2, 0.08, 0.22), DARK_WOOD])
			out.append([Vector3(-0.5, 0.86, -0.2), Vector3(0.3, 0.1, 0.12), METAL])
			return out
		Blocks.BED:
			return [
				[Vector3(0, 0.12, 0), Vector3(0.84, 0.24, 1.9), DARK_WOOD],
				[Vector3(0, 0.34, 0.1), Vector3(0.9, 0.2, 1.7), CLOTH],
				[Vector3(0, 0.46, -0.72), Vector3(0.7, 0.16, 0.3), Color(0.9, 0.9, 0.88)],
				[Vector3(0, 0.3, -0.95), Vector3(0.9, 0.6, 0.12), WOOD]]
		Blocks.CHEST:
			return chest_body_boxes() + chest_lid_boxes(Vector3.ZERO)
		Blocks.SHAPER:
			var out2: Array = []
			for sx2 in [-0.78, 0.78]:
				out2.append([Vector3(sx2, 0.3, 0), Vector3(0.22, 0.6, 0.5), STONE])
			out2.append([Vector3(0, 0.66, 0), Vector3(1.94, 0.14, 0.86), METAL])
			out2.append([Vector3(0.45, 0.8, 0), Vector3(0.5, 0.16, 0.5), STONE])
			out2.append([Vector3(-0.5, 0.78, 0.1), Vector3(0.3, 0.1, 0.3), DARK])
			return out2
		Blocks.SMELTER:
			return [
				[Vector3(0, 0.5, 0), Vector3(0.92, 1.0, 0.92), STONE],
				[Vector3(0, 1.15, 0), Vector3(0.5, 0.3, 0.5), STONE],
				[Vector3(0, 1.45, 0), Vector3(0.34, 0.3, 0.34), DARK],
				[Vector3(0, 0.35, -0.44), Vector3(0.46, 0.44, 0.12), EMBER]]
		Blocks.FORGE:
			return [
				[Vector3(-0.5, 0.55, 0), Vector3(0.94, 1.1, 0.94), STONE],
				[Vector3(-0.5, 1.3, 0), Vector3(0.4, 0.5, 0.4), DARK],
				[Vector3(-0.5, 0.4, -0.45), Vector3(0.5, 0.5, 0.12), EMBER],
				[Vector3(0.62, 0.42, 0), Vector3(0.9, 0.84, 0.9), METAL],
				[Vector3(0.62, 0.95, 0), Vector3(0.7, 0.24, 0.7), DARK],
				[Vector3(0.62, 1.2, 0.2), Vector3(0.18, 0.3, 0.18), METAL]]
		Blocks.GENERATOR:
			return [
				[Vector3(0, 0.35, 0), Vector3(0.9, 0.7, 0.9), METAL],
				[Vector3(0, 0.78, 0), Vector3(0.6, 0.22, 0.6), DARK],
				[Vector3(0, 0.5, -0.47), Vector3(0.4, 0.2, 0.08), GLOW],
				[Vector3(0.3, 0.92, 0), Vector3(0.14, 0.18, 0.14), METAL]]
		Blocks.POWER_BAY:
			return power_bay_boxes(false, 0.0)
		Blocks.OXYGEN_PLANT:
			return [
				[Vector3(0, 0.2, 0), Vector3(0.9, 0.4, 0.9), METAL],
				[Vector3(0, 1.0, 0), Vector3(0.7, 1.2, 0.7), GLASS],
				[Vector3(0, 1.7, 0), Vector3(0.8, 0.2, 0.8), METAL],
				[Vector3(0.36, 0.9, 0.36), Vector3(0.12, 1.0, 0.12), METAL]]
		Blocks.HEATER:
			return [
				[Vector3(0, 0.42, 0), Vector3(0.8, 0.84, 0.8), STONE],
				[Vector3(0, 0.88, 0), Vector3(0.6, 0.12, 0.6), METAL],
				[Vector3(0, 0.45, -0.41), Vector3(0.5, 0.5, 0.06), EMBER]]
		Blocks.COOLER:
			var out4: Array = []
			out4.append([Vector3(0, 0.4, 0), Vector3(0.8, 0.8, 0.8), METAL])
			for i in 4:
				out4.append([Vector3(0, 0.2 + i * 0.18, -0.42), Vector3(0.74, 0.08, 0.1), GLASS])
			return out4
		Blocks.CLIMATE_UNIT:
			return [
				[Vector3(0, 0.45, 0), Vector3(0.86, 0.9, 0.86), METAL],
				[Vector3(0, 1.2, 0), Vector3(0.7, 0.6, 0.7), DARK],
				[Vector3(0, 1.58, 0), Vector3(0.5, 0.16, 0.5), METAL],
				[Vector3(0, 0.9, -0.44), Vector3(0.5, 0.16, 0.06), GLOW]]
		Blocks.FABRICATOR:
			return [
				[Vector3(0, 0.15, 0), Vector3(1.94, 0.3, 0.9), DARK],
				[Vector3(-0.5, 0.55, 0), Vector3(0.8, 0.5, 0.8), METAL],
				[Vector3(0.6, 0.7, 0), Vector3(0.9, 0.8, 0.8), METAL],
				[Vector3(0.6, 1.14, 0), Vector3(0.6, 0.1, 0.6), GLOW],
				[Vector3(-0.5, 0.86, 0), Vector3(0.5, 0.12, 0.5), GLASS]]
		Blocks.SHIPWORKS:
			var out5: Array = []
			# A shed: a floor, a gantry over it, and a frame to build in.
			out5.append([Vector3(0, 0.1, 0), Vector3(2.9, 0.2, 1.9), DARK])
			for sx3 in [-1.3, 1.3]:
				for sz in [-0.8, 0.8]:
					out5.append([Vector3(sx3, 0.9, sz), Vector3(0.22, 1.6, 0.22), METAL])
			out5.append([Vector3(0, 1.75, 0), Vector3(2.9, 0.2, 1.9), METAL])
			out5.append([Vector3(0, 1.5, 0), Vector3(1.2, 0.3, 1.2), DARK])
			out5.append([Vector3(0, 1.2, 0), Vector3(0.3, 0.5, 0.3), GLOW])
			out5.append([Vector3(-1.3, 0.5, 0), Vector3(0.5, 0.8, 1.4), METAL])
			return out5
	# Anything without a model of its own is a plain crate, so a station added
	# later still stands somewhere rather than being invisible.
	return [[Vector3(0, 0.4, 0), Vector3(0.85, 0.8, 0.85), METAL]]


## Which colours are lights rather than paint, so a station reads as running.
static func glows(c: Color) -> bool:
	return c == EMBER or c == GLOW


## One mesh for the whole station, in its own space (y 0 on the ground).
static func mesh_for(kind: int, ghost := false) -> ArrayMesh:
	var m := _mesh_from(boxes_for(kind))
	if m.get_surface_count() > 0:
		m.surface_set_material(0, material(ghost))
	return m


## Boxes to a mesh, with the lit material stations share.
static func _mesh_from(boxes: Array) -> ArrayMesh:
	var st := SurfaceTool.new()
	st.begin(Mesh.PRIMITIVE_TRIANGLES)
	for b in boxes:
		var c: Color = b[2]
		var p0: Vector3 = (b[0] as Vector3) - (b[1] as Vector3) * 0.5
		var p1: Vector3 = (b[0] as Vector3) + (b[1] as Vector3) * 0.5
		for fi in 6:
			# Flat colour: this model is lit by the sun like anything else in the
			# world, and face shading baked in on top of that shaded it twice --
			# which is what made the faces look wrong rather than merely dark.
			st.set_color(c)
			st.set_normal(Vector3(Chunk._WFACE[fi]))
			var q := Chunk._box_face(p0, p1, fi)
			# Reversed on purpose. Chunk._box_face lists each quad in the order
			# the voxel mesher wants, and that mesher only gets away with it
			# because voxel_block.gdshader sets cull_disabled (see the note at
			# the top of it). A model lit by an ordinary material culls its back
			# faces, so laid out that way you see the INSIDE of every box and
			# the shading comes out inverted -- the top of a seat darker than
			# its sides. Wound the other way round, it culls correctly.
			st.add_vertex(q[0]); st.add_vertex(q[2]); st.add_vertex(q[1])
			st.add_vertex(q[0]); st.add_vertex(q[3]); st.add_vertex(q[2])
	var m2 := st.commit()
	if m2.get_surface_count() > 0:
		m2.surface_set_material(0, material(false))
	return m2


## The model shrunk into the unit cube ItemIcon photographs.
static func icon_mesh(kind: int) -> ArrayMesh:
	return _icon_from(boxes_for(kind))


## Any box model, centred and scaled into the unit cube the icon camera frames,
## with the face shading baked in -- an icon has no sun on it.
static func _icon_from(boxes: Array) -> ArrayMesh:
	var lo := Vector3(1e9, 1e9, 1e9)
	var hi := -lo
	for b in boxes:
		lo = lo.min((b[0] as Vector3) - (b[1] as Vector3) * 0.5)
		hi = hi.max((b[0] as Vector3) + (b[1] as Vector3) * 0.5)
	var ext := hi - lo
	var sc := 1.0 / maxf(maxf(ext.x, ext.y), maxf(ext.z, 0.001))
	var shift := -(lo + hi) * 0.5
	var st := SurfaceTool.new()
	st.begin(Mesh.PRIMITIVE_TRIANGLES)
	for b in boxes:
		var c: Color = b[2]
		var p0: Vector3 = ((b[0] as Vector3) + shift - (b[1] as Vector3) * 0.5) * sc
		var p1: Vector3 = ((b[0] as Vector3) + shift + (b[1] as Vector3) * 0.5) * sc
		for fi in 6:
			var shade := Chunk._face_shade(fi / 2, 1 if (fi % 2) == 0 else -1)
			st.set_color(Color(c.r * shade, c.g * shade, c.b * shade, c.a))
			st.set_normal(Vector3(Chunk._WFACE[fi]))
			var q := Chunk._box_face(p0, p1, fi)
			st.add_vertex(q[0]); st.add_vertex(q[2]); st.add_vertex(q[1])
			st.add_vertex(q[0]); st.add_vertex(q[3]); st.add_vertex(q[2])
	var m := st.commit()
	if m.get_surface_count() > 0:
		var mat := StandardMaterial3D.new()
		mat.vertex_color_use_as_albedo = true
		mat.roughness = 0.8
		mat.cull_mode = BaseMaterial3D.CULL_DISABLED
		m.surface_set_material(0, mat)
	return m


static func material(ghost := false) -> StandardMaterial3D:
	var mat := StandardMaterial3D.new()
	mat.vertex_color_use_as_albedo = true
	mat.roughness = 0.7
	mat.metallic = 0.15
	if ghost:
		mat.transparency = BaseMaterial3D.TRANSPARENCY_ALPHA
		mat.albedo_color = Color(1, 1, 1, 0.45)
		mat.shading_mode = BaseMaterial3D.SHADING_MODE_UNSHADED
		mat.cull_mode = BaseMaterial3D.CULL_DISABLED
	else:
		# A machine has its own small glow so it reads as running after dark,
		# but not enough to flatten the daylight shading.
		mat.emission_enabled = true
		mat.emission = Color(1, 0.8, 0.5)
		mat.emission_energy_multiplier = 0.06
	return mat


## The battery cradle, and what is sitting in it.
##
## A round pad one cell across with four arms standing up round its edge, which
## close over the battery when one is seated and stand open when it is not. The
## contact hub in the middle is exposed either way, so an empty cradle reads as
## a thing waiting for something rather than as a broken thing.
const BATT_Y0 := 0.22     # where the battery sits on the hub
const BATT_Y1 := 0.80
const G0 := 0.34          # the gauge's track, up the battery's face
const G1 := 0.72
const GZ := -0.21


static func power_bay_boxes(has_battery: bool, _charge: float) -> Array:
	const CASE := Color(0.31, 0.34, 0.38)
	const DEEP := Color(0.15, 0.17, 0.20)
	const CONT := Color(0.74, 0.62, 0.30)   # contacts
	const CELL := Color(0.34, 0.40, 0.30)   # the battery's own casing
	const TRACK := Color(0.09, 0.10, 0.12)  # the empty part of the gauge
	var out: Array = []
	out.append_array(_disc(0.05, 0.10, 0.46, DEEP))     # foot
	out.append_array(_disc(0.13, 0.08, 0.42, CASE))     # pad
	out.append_array(_disc(0.19, 0.06, 0.24, DEEP))     # hub the battery stands on
	out.append([Vector3(0, 0.22, 0), Vector3(0.20, 0.04, 0.20), CONT])  # contact plate
	# Four arms round the rim, holding the battery near its foot. They are low
	# on purpose: an arm tall enough to reach the top of the cell is a pillar,
	# and four pillars hide the one thing on this machine worth reading.
	# Seated, they close in and grip; empty, they stand back and open.
	var grip: float = 0.05 if has_battery else 0.0
	var lean: float = 0.0 if has_battery else 0.06
	for dir in [Vector3(1, 0, 0), Vector3(-1, 0, 0), Vector3(0, 0, 1), Vector3(0, 0, -1)]:
		var d: Vector3 = dir
		var across := Vector3(absf(d.z), 0, absf(d.x))   # the arm's width axis
		var post: Vector3 = d * (0.35 + lean)
		out.append([Vector3(post.x, 0.28, post.z),
			Vector3(0.08 + across.x * 0.16, 0.24, 0.08 + across.z * 0.16), CASE])
		var tip: Vector3 = d * (0.32 + lean - grip)
		out.append([Vector3(tip.x, 0.40, tip.z),
			Vector3(0.09 + across.x * 0.20, 0.07, 0.09 + across.z * 0.20), CONT])
	if not has_battery:
		return out
	out.append_array(battery_boxes(BATT_Y0))
	return out


## The battery on its own, standing with its foot at `y0`: a cell with banded
## ends, a terminal on top and the dark track of its gauge up the face. Shared
## by the cradle, which seats one, and the inventory icon, which photographs
## one -- so the thing in your bag is the thing you slot in.
static func battery_boxes(y0: float) -> Array:
	const DEEP := Color(0.15, 0.17, 0.20)
	const CONT := Color(0.74, 0.62, 0.30)
	const CELL := Color(0.34, 0.40, 0.30)
	const TRACK := Color(0.09, 0.10, 0.12)
	var h: float = BATT_Y1 - BATT_Y0
	var cy: float = y0 + h * 0.5
	return [
		[Vector3(0, cy, 0), Vector3(0.42, h, 0.42), CELL],
		[Vector3(0, y0 + h - 0.03, 0), Vector3(0.36, 0.07, 0.36), DEEP],
		[Vector3(0, y0 + 0.03, 0), Vector3(0.36, 0.07, 0.36), DEEP],
		[Vector3(0, y0 + h + 0.04, 0), Vector3(0.12, 0.06, 0.12), CONT],  # terminal
		# The gauge runs up the middle of the face, inset into the casing with a
		# margin of cell either side -- the only thing on this you read, so
		# nothing stands in front of it.
		[Vector3(0, y0 + (G0 + G1) * 0.5 - BATT_Y0, GZ), Vector3(0.20, G1 - G0, 0.03), TRACK],
	]


## The battery shrunk into the unit cube ItemIcon photographs. It is drawn with
## its gauge EMPTY: the slot's own bar is what says how much is in this one, and
## a picture that showed a level would contradict it.
static func battery_icon_mesh() -> ArrayMesh:
	return _icon_from(battery_boxes(0.0))


## A circle in axis-aligned boxes: bands across Z, each as wide as the chord at
## that depth. Five is enough to read as round at a block's scale, and it keeps
## to the same flat-box vocabulary as everything else in the game.
static func _disc(cy: float, h: float, r: float, col: Color) -> Array:
	var out: Array = []
	const BANDS := 5
	for i in BANDS:
		var z0: float = -r + 2.0 * r * float(i) / float(BANDS)
		var z1: float = -r + 2.0 * r * float(i + 1) / float(BANDS)
		var zm: float = (z0 + z1) * 0.5
		var half: float = sqrt(maxf(r * r - zm * zm, 0.0))
		out.append([Vector3(0, cy, zm), Vector3(half * 2.0, h, z1 - z0), col])
	return out


## The part of the cradle that is its own light: the charge drawn in the gauge.
## Unshaded, so it reads the same in a dark cabin as it does outside in the sun
## -- an indicator that goes dim when the room does is not an indicator.
static func power_bay_lit(has_battery: bool, charge: float) -> Array:
	if not has_battery:
		return []
	var f := clampf(charge, 0.0, 1.0)
	if f <= 0.001:
		return []
	var h: float = (G1 - G0) * f
	return [[Vector3(0, G0 + h * 0.5, GZ - 0.015), Vector3(0.15, h, 0.03), gauge_colour(f)]]


## Green when it is full, amber in the middle, red when it is nearly out -- the
## same reading as a tool's wear bar, so the colour means the same thing
## wherever you see it.
static func gauge_colour(f: float) -> Color:
	return Color(1.0, 0.2, 0.1).lerp(Color(0.3, 0.9, 0.2), clampf(f, 0.0, 1.0))


## The cradle's mesh for a given state. The battery's gauge is part of the
## geometry, so this is rebuilt when what it would show changes.
static func power_bay_mesh(has_battery: bool, charge: float) -> ArrayMesh:
	var m := _mesh_from(power_bay_boxes(has_battery, charge))
	var lit := power_bay_lit(has_battery, charge)
	if lit.is_empty():
		return m
	var sub := _mesh_from(lit)
	if sub.get_surface_count() == 0:
		return m
	var mat := StandardMaterial3D.new()
	mat.vertex_color_use_as_albedo = true
	mat.shading_mode = BaseMaterial3D.SHADING_MODE_UNSHADED
	m.add_surface_from_arrays(Mesh.PRIMITIVE_TRIANGLES, sub.surface_get_arrays(0))
	m.surface_set_material(m.get_surface_count() - 1, mat)
	return m


## Where a chest's lid is hinged: the top of the back edge, so it swings up and
## back the way a lid does.
const CHEST_HINGE := Vector3(0, 0.54, 0.37)


## The chest without its lid. Split out because the lid is a separate node that
## turns on a hinge -- a lid that opens is worth more than a lid drawn open.
static func chest_body_boxes() -> Array:
	return [
		[Vector3(0, 0.28, 0), Vector3(0.84, 0.56, 0.7), WOOD],
	]


## The lid and its clasp, given where the hinge sits. Pass CHEST_HINGE to get
## them in the lid node's own space (hinge at the origin), or ZERO to get the
## whole chest in one piece, shut, for the icon and the placement ghost.
static func chest_lid_boxes(origin: Vector3) -> Array:
	return [
		[Vector3(0, 0.62, 0) - origin, Vector3(0.88, 0.16, 0.74), DARK_WOOD],
		[Vector3(0, 0.44, -0.37) - origin, Vector3(0.18, 0.18, 0.06), METAL],
	]


## A mesh from an arbitrary box list, for the parts of a station that move.
static func mesh_from_boxes(boxes: Array) -> ArrayMesh:
	var m := _mesh_from(boxes)
	if m.get_surface_count() > 0:
		m.surface_set_material(0, material(false))
	return m
