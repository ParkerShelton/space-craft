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
		Blocks.GENERATOR:
			return generator_boxes(false, 0.0, false, 0.0)
		Blocks.POWER_BAY:
			return power_bay_boxes(false, 0.0)
		Blocks.ANVIL:
			return anvil_boxes()
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
			# The Press. For the icon and the placing ghost the ram and lever
			# are drawn in, at rest; the placed one moves them (see Station).
			var pr: Array = press_boxes()
			for rb in press_ram_boxes():
				pr.append([(rb[0] as Vector3) + Vector3(0, PRESS_RAM_UP, 0), rb[1], rb[2]])
			for lb in press_lever_boxes():
				pr.append([(lb[0] as Vector3) + PRESS_LEVER, lb[1], lb[2]])
			return pr
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


# --- the generator -------------------------------------------------------------
#
# Two places to put things and a switch to throw, all on the outside where you
# can see them: a cradle on the left that holds a battery, a hopper on the right
# that you shovel ore into, and a lever on the front face. Everything the
# machine is doing is readable from across the room without opening anything.

## The cradle's centre, on top of the case, and the top of the case itself.
const GEN_TOP := 0.72
const GEN_CRADLE := Vector3(-0.24, GEN_TOP, 0)
const GEN_HOPPER := Vector3(0.24, GEN_TOP, 0)
## Where the lever turns: on the front face, on the right-hand side, high
## enough that thrown down it still clears the floor.
const GEN_LEVER := Vector3(0.36, 0.42, -0.47)


## The case, the two bays and the gauge. The lever is NOT here -- it is a node
## of its own so it can actually swing (see `generator_lever_boxes`).
static func generator_boxes(has_battery: bool, _charge: float, _burning: bool,
		_power: float) -> Array:
	const CASE := Color(0.44, 0.40, 0.33)
	const DEEP := Color(0.17, 0.16, 0.15)
	const CONT := Color(0.74, 0.62, 0.30)
	const TRACK := Color(0.09, 0.10, 0.12)
	var out: Array = [
		[Vector3(0, 0.34, 0), Vector3(0.92, 0.68, 0.92), CASE],
		[Vector3(0, GEN_TOP - 0.02, 0), Vector3(0.94, 0.08, 0.94), DEEP],
		# A stack, because a thing that burns has to put it somewhere.
		[Vector3(0.30, 0.95, 0.30), Vector3(0.20, 0.42, 0.20), DEEP],
	]
	# The battery cradle: a hub with four short arms, the same shape as the
	# ship's power bay, so a cradle is a cradle wherever you meet one.
	out.append([GEN_CRADLE + Vector3(0, 0.03, 0), Vector3(0.44, 0.06, 0.44), DEEP])
	out.append([GEN_CRADLE + Vector3(0, 0.07, 0), Vector3(0.20, 0.04, 0.20), CONT])
	var grip: float = 0.04 if has_battery else 0.0
	var lean: float = 0.0 if has_battery else 0.05
	for d in [Vector3(1, 0, 0), Vector3(-1, 0, 0), Vector3(0, 0, 1), Vector3(0, 0, -1)]:
		var dir: Vector3 = d
		var across := Vector3(absf(dir.z), 0, absf(dir.x))
		var post: Vector3 = dir * (0.19 + lean)
		out.append([GEN_CRADLE + Vector3(post.x, 0.13, post.z),
			Vector3(0.07 + across.x * 0.13, 0.18, 0.07 + across.z * 0.13), CASE])
		var tip: Vector3 = dir * (0.17 + lean - grip)
		out.append([GEN_CRADLE + Vector3(tip.x, 0.23, tip.z),
			Vector3(0.08 + across.x * 0.16, 0.06, 0.08 + across.z * 0.16), CONT])
	if has_battery:
		for b in battery_boxes(0.0):
			var bb: Array = b
			var c: Vector3 = bb[0]
			var sz: Vector3 = bb[1]
			# Two thirds the size of a bay's: this one shares its roof with a
			# fuel hopper, and a full-height cell would stand over the lot.
			out.append([GEN_CRADLE + Vector3(c.x * 0.66, 0.08 + c.y * 0.66, c.z * 0.66),
				sz * 0.66, bb[2]])
	# The hopper: a mouth in the roof you drop ore into, with a lip round it.
	out.append([GEN_HOPPER, Vector3(0.40, 0.10, 0.40), DEEP])
	out.append([GEN_HOPPER + Vector3(0, 0.05, 0), Vector3(0.30, 0.06, 0.30),
		Color(0.06, 0.05, 0.05)])
	for d2 in [Vector3(1, 0, 0), Vector3(-1, 0, 0), Vector3(0, 0, 1), Vector3(0, 0, -1)]:
		var dir2: Vector3 = d2
		var across2 := Vector3(absf(dir2.z), 0, absf(dir2.x))
		out.append([GEN_HOPPER + Vector3(dir2.x * 0.19, 0.06, dir2.z * 0.19),
			Vector3(0.05 + across2.x * 0.38, 0.10, 0.05 + across2.z * 0.38), CASE])
	# The window in the firebox, and the power gauge's track beside it.
	out.append([Vector3(-0.18, 0.30, -0.47), Vector3(0.34, 0.24, 0.05), DEEP])
	out.append([Vector3(-0.18, 0.58, -0.47), Vector3(0.44, 0.07, 0.04), TRACK])
	return out


## What is lit on it: the fire behind the window while it burns, and the filled
## part of the power gauge.
static func generator_lit(burning: bool, power: float) -> Array:
	var out: Array = []
	if burning:
		out.append([Vector3(-0.18, 0.30, -0.495), Vector3(0.30, 0.20, 0.03), EMBER])
	var f := clampf(power, 0.0, 1.0)
	if f > 0.001:
		var w: float = 0.42 * f
		out.append([Vector3(-0.39 + w * 0.5, 0.58, -0.495), Vector3(w, 0.05, 0.03),
			gauge_colour(f)])
	return out


## The lever, in the hinge's own space, so the node it lives on can turn it
## (Station.lever_angle). Thrown up is on and down is off, which is the way
## round every switch in a machine shop works.
static func generator_lever_boxes() -> Array:
	const CASE := Color(0.44, 0.40, 0.33)
	const HANDLE := Color(0.72, 0.24, 0.20)
	return [
		[Vector3(0, 0.13, -0.02), Vector3(0.06, 0.26, 0.06), CASE],
		[Vector3(0, 0.27, -0.02), Vector3(0.11, 0.11, 0.11), HANDLE],
	]


## The generator's mesh for a given state: the case, whatever is seated in the
## cradle, and the lit parts -- fire, power gauge, the battery's own gauge.
static func generator_mesh(has_battery: bool, charge: float, burning: bool,
		power: float) -> ArrayMesh:
	var m := _mesh_from(generator_boxes(has_battery, charge, burning, power))
	var lit := generator_lit(burning, power)
	if has_battery and charge > 0.001:
		# The seated battery's own gauge, shrunk with it.
		var h: float = (G1 - G0) * 0.66 * clampf(charge, 0.0, 1.0)
		lit.append([GEN_CRADLE + Vector3(0, 0.08 + (G0 - BATT_Y0) * 0.66 + h * 0.5,
			GZ * 0.66 - 0.012), Vector3(0.10, h, 0.03), gauge_colour(charge)])
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


# --- the anvil -------------------------------------------------------------------
#
# The classic shape, because everybody knows it on sight: a broad foot, a
# narrow waist, a flat face, the horn out one end and a step at the other. What
# is being worked sits on the face and is drawn as what it currently IS -- a
# fat ingot, a long bar, a thin sheet, a flat plate -- so every strike visibly
# changes it. It glows while it is on there: this is hot work, and a piece that
# looks the same whether it has been in the fire or not reads as a button.

## The top of the face, where a workpiece rests.
const ANVIL_FACE := 0.67


static func anvil_boxes() -> Array:
	const IRON := Color(0.27, 0.28, 0.31)
	const DEEP := Color(0.16, 0.17, 0.19)
	const FACE := Color(0.46, 0.48, 0.52)
	return [
		[Vector3(0, 0.07, 0), Vector3(0.72, 0.14, 0.52), DEEP],       # foot
		[Vector3(0, 0.17, 0), Vector3(0.56, 0.08, 0.40), IRON],       # plinth
		[Vector3(0, 0.34, 0), Vector3(0.34, 0.28, 0.26), IRON],       # waist
		[Vector3(0.02, 0.57, 0), Vector3(0.62, 0.18, 0.34), IRON],    # body
		[Vector3(0.02, ANVIL_FACE - 0.005, 0), Vector3(0.58, 0.01, 0.30), FACE],
		[Vector3(-0.38, 0.58, 0), Vector3(0.16, 0.13, 0.20), IRON],   # horn
		[Vector3(-0.50, 0.60, 0), Vector3(0.10, 0.08, 0.12), IRON],
		[Vector3(-0.575, 0.61, 0), Vector3(0.05, 0.05, 0.06), IRON],
		[Vector3(0.36, 0.60, 0), Vector3(0.08, 0.12, 0.30), IRON],    # heel
	]


## The main slab of each shape, and how far through the NEXT change of shape a
## blow takes it. Between the big changes the piece creeps toward the next
## shape a little with every blow -- then, at the stage, it jumps the rest of
## the way, so a change of shape is still an unmistakable event.
const PIECE_INGOT := Vector3(0.26, 0.09, 0.14)
const PIECE_BAR := Vector3(0.46, 0.06, 0.07)
const PIECE_SHEET := Vector3(0.40, 0.025, 0.26)
const PIECE_PLATE := Vector3(0.48, 0.044, 0.32)
const PIECE_CREEP := 0.6


## The workpiece sitting on the face, as [centre, size, colour] boxes. `shape`
## is Blocks.smith_shape's answer ("" is nothing on there); `t` is how far
## through that shape's stage it is, 0..1; `hits` seeds the small unevenness
## every blow leaves.
static func anvil_piece_boxes(shape: String, col: Color, t: float = 0.0,
		hits: int = 0) -> Array:
	var y := ANVIL_FACE
	var c := Vector3(0.02, 0, 0)
	var dark := col.darkened(0.55)
	var k: float = clampf(t, 0.0, 1.0) * PIECE_CREEP
	# Hammered, not machined: each blow nudges it a hair off true.
	var rng := RandomNumberGenerator.new()
	rng.seed = hits * 7919 + 13
	var wob := Vector3(rng.randf_range(-0.012, 0.012), 0.0, rng.randf_range(-0.01, 0.01))
	match shape:
		"ingot":
			# A cast ingot: a block with its top a little narrower than its
			# base, the way it comes out of the mould -- drawn out toward a bar
			# a little more with each blow.
			var main: Vector3 = PIECE_INGOT.lerp(PIECE_BAR, k) + wob
			var top := Vector3(0.21, 0.02, 0.10).lerp(Vector3(0.36, 0.004, 0.05), k)
			return [[c + Vector3(0, y + main.y * 0.5, 0), main, col],
				[c + Vector3(0, y + main.y + top.y * 0.5, 0), top, col]]
		"bar":
			var bar: Vector3 = PIECE_BAR.lerp(PIECE_SHEET, k) + wob
			return [[c + Vector3(0, y + bar.y * 0.5, 0), bar, col]]
		"sheet":
			var sh: Vector3 = PIECE_SHEET.lerp(PIECE_PLATE, k) + wob
			return [[c + Vector3(0, y + sh.y * 0.5, 0), sh, col]]
		"plate", "cracking":
			var out: Array = [[c + Vector3(0, y + 0.022, 0), PIECE_PLATE, col],
				# a raised rim round the edge, which is what makes a plate a
				# plate rather than a thick sheet
				[c + Vector3(0, y + 0.047, -0.15), Vector3(0.48, 0.006, 0.02), col.lightened(0.15)],
				[c + Vector3(0, y + 0.047, 0.15), Vector3(0.48, 0.006, 0.02), col.lightened(0.15)]]
			if shape == "cracking":
				# Splitting: a jagged dark line most of the way across it.
				for seg in [[Vector3(-0.14, 0, -0.06), Vector3(0.12, 0, 0.014)],
						[Vector3(-0.05, 0, -0.02), Vector3(0.014, 0, 0.09)],
						[Vector3(0.03, 0, 0.03), Vector3(0.13, 0, 0.014)],
						[Vector3(0.1, 0, 0.07), Vector3(0.014, 0, 0.08)]]:
					out.append([c + (seg[0] as Vector3) + Vector3(0, y + 0.046, 0),
						(seg[1] as Vector3) + Vector3(0, 0.004, 0), dark])
			return out
		"scrap":
			# Torn, folded and sitting in pieces.
			return [[c + Vector3(-0.08, y + 0.025, -0.05), Vector3(0.16, 0.05, 0.11), dark],
				[c + Vector3(0.09, y + 0.04, 0.04), Vector3(0.12, 0.08, 0.13), dark.lightened(0.1)],
				[c + Vector3(-0.01, y + 0.06, 0.09), Vector3(0.09, 0.03, 0.15), dark],
				[c + Vector3(0.14, y + 0.015, -0.1), Vector3(0.07, 0.03, 0.06), dark.lightened(0.05)]]
	return []


## What is waiting its turn, stacked on the floor at the front (-Z) of the anvil:
## small cold ingots (or bars, or sheets -- they are drawn the same), four to a
## row and a second row on top. Past eight the heap does not get any bigger;
## the look line says how many.
static func anvil_pile_boxes(n: int, col: Color) -> Array:
	if n <= 0:
		return []
	var cold: Color = Color(0.62, 0.62, 0.64).lerp(Color(col.r, col.g, col.b), 0.5)
	var out: Array = []
	for i in mini(n, 8):
		var row: int = i / 4
		var x: float = -0.27 + float(i % 4) * 0.15 + (0.075 if row == 1 else 0.0)
		out.append([Vector3(x, 0.028 + float(row) * 0.056, -0.38), Vector3(0.12, 0.052, 0.08),
			cold if i % 2 == 0 else cold.darkened(0.08)])
	return out


## The anvil with `shape` on its face in `col`, `t` through its stage, and
## `pile` more waiting beside it. The piece is its own surface, unshaded and
## pushed toward the colour of hot metal -- except scrap, which has gone cold.
static func anvil_mesh(shape: String, col: Color, t: float = 0.0, hits: int = 0,
		pile: int = 0, pile_col: Color = Color(0.7, 0.68, 0.64)) -> ArrayMesh:
	var body: Array = anvil_boxes()
	body.append_array(anvil_pile_boxes(pile, pile_col))
	var m := _mesh_from(body)
	if shape == "":
		return m
	var hot: bool = shape != "scrap"
	var c: Color = col.lerp(EMBER, 0.75).lightened(0.2) if hot else col
	var sub := _mesh_from(anvil_piece_boxes(shape, c, t, hits))
	if sub.get_surface_count() == 0:
		return m
	var mat := StandardMaterial3D.new()
	mat.vertex_color_use_as_albedo = true
	if hot:
		mat.shading_mode = BaseMaterial3D.SHADING_MODE_UNSHADED
	m.add_surface_from_arrays(Mesh.PRIMITIVE_TRIANGLES, sub.surface_get_arrays(0))
	m.surface_set_material(m.get_surface_count() - 1, mat)
	return m


# --- the press --------------------------------------------------------------------
#
# A bench press, two blocks wide: a heavy bed on a plinth, two uprights and a
# crown beam over it, and a ram hanging from the beam. The parts you lay on
# the bed sit on it as what they are. The lever is on the housing at the
# right-hand end; pull it and the ram comes down.

const PRESS_BED_Y := 0.42          # the top of the bed, where parts rest
const PRESS_BED_X := -0.25         # the middle of the bed
const PRESS_RAM_UP := 1.22         # the ram's head, raised
const PRESS_RAM_DOWN := 0.56       # ...and come down onto the parts
const PRESS_LEVER := Vector3(0.72, 0.6, -0.31)  # the lever's hinge, on the front
const PRESS_STEEL := Color(0.40, 0.42, 0.46)


static func press_spot(i: int) -> Vector3:
	return Vector3(PRESS_BED_X + (float(i) - 1.5) * 0.27, PRESS_BED_Y, 0)


static func press_boxes() -> Array:
	const RED := Color(0.72, 0.22, 0.18)
	return [
		[Vector3(0, 0.12, 0), Vector3(1.9, 0.24, 0.86), DARK],                  # plinth
		[Vector3(PRESS_BED_X, 0.33, 0), Vector3(1.2, 0.18, 0.72), PRESS_STEEL],  # bed
		[Vector3(PRESS_BED_X, PRESS_BED_Y - 0.004, 0), Vector3(1.1, 0.01, 0.62),
			PRESS_STEEL.lightened(0.2)],                                          # die face
		[Vector3(-0.93, 0.95, 0), Vector3(0.14, 1.3, 0.22), PRESS_STEEL],        # uprights
		[Vector3(0.43, 0.95, 0), Vector3(0.14, 1.3, 0.22), PRESS_STEEL],
		[Vector3(PRESS_BED_X, 1.66, 0), Vector3(1.52, 0.2, 0.34), DARK],         # crown
		[Vector3(0.72, 0.45, 0), Vector3(0.42, 0.42, 0.6), METAL],              # housing
		[Vector3(0.72, 0.36, -0.305), Vector3(0.12, 0.05, 0.01), RED],          # a warning stripe
	]


## The ram, in its own space: the head at the origin, the shaft up into the
## crown. The node it lives on is raised and lowered.
static func press_ram_boxes() -> Array:
	return [
		[Vector3(PRESS_BED_X, 0, 0), Vector3(1.0, 0.14, 0.6), PRESS_STEEL.darkened(0.15)],
		[Vector3(PRESS_BED_X, -0.075, 0), Vector3(0.94, 0.01, 0.54), PRESS_STEEL.lightened(0.15)],
		# Long enough to stay in the crown with the ram all the way down: a
		# ram hanging off nothing looks like it fell off.
		[Vector3(PRESS_BED_X, 0.66, 0), Vector3(0.14, 1.2, 0.14), PRESS_STEEL],
	]


## The lever, from its hinge: upright at rest, pulled toward you to press.
static func press_lever_boxes() -> Array:
	return [
		[Vector3(0, 0.02, 0.02), Vector3(0.1, 0.1, 0.06), DARK],
		[Vector3(0, 0.21, 0), Vector3(0.05, 0.42, 0.05), METAL],
		[Vector3(0, 0.44, 0), Vector3(0.1, 0.1, 0.1), Color(0.72, 0.24, 0.20)],
	]


## An item as boxes, fitted into a spot `size` across and standing on `at`:
## its own model where it has one (metal stock, tools, a battery), a tinted
## block where it does not. Anything taller than it is wide is laid down.
static func press_item_boxes(item: Dictionary, at: Vector3, size: float) -> Array:
	var id := int(item.get("id", Blocks.AIR))
	var mat: Dictionary = item.get("mat", {})
	var tint: Color = mat.get("color", Color(0, 0, 0, 0))
	var raw: Array = ItemModels.boxes_for(id, tint)
	if raw.is_empty() and ToolModels.has_model(id):
		raw = ToolModels.boxes_for(id, tint)
	if raw.is_empty() and id == Blocks.BATTERY:
		raw = battery_boxes(0.0)
	if raw.is_empty():
		var col: Color = tint if tint.a > 0.0 else Blocks.color_of(id)
		raw = [[Vector3.ZERO, Vector3(1, 0.5, 1), col]]
	var lo := Vector3(1e9, 1e9, 1e9)
	var hi := -lo
	for b in raw:
		lo = lo.min((b[0] as Vector3) - (b[1] as Vector3) * 0.5)
		hi = hi.max((b[0] as Vector3) + (b[1] as Vector3) * 0.5)
	var ext := hi - lo
	var lay: bool = ext.y > maxf(ext.x, ext.z)
	if lay:
		ext = Vector3(ext.y, ext.x, ext.z)
	var k: float = size / maxf(maxf(ext.x, ext.z), 0.001)
	var mid := (lo + hi) * 0.5
	var out: Array = []
	for b in raw:
		var c: Vector3 = (b[0] as Vector3) - mid
		var sz: Vector3 = b[1]
		if lay:
			c = Vector3(c.y, c.x, c.z)
			sz = Vector3(sz.y, sz.x, sz.z)
		out.append([at + Vector3(c.x * k, c.y * k + ext.y * k * 0.5, c.z * k), sz * k, b[2]])
	return out


## The press with these parts on its bed and `output` (if any) waiting where
## the ram left it.
static func press_mesh(parts: Array, output: Dictionary) -> ArrayMesh:
	var boxes: Array = press_boxes()
	for i in parts.size():
		boxes.append_array(press_item_boxes(parts[i], press_spot(i), 0.22))
	if not output.is_empty():
		boxes.append_array(press_item_boxes(output,
			Vector3(PRESS_BED_X, PRESS_BED_Y, 0), 0.42))
	return _mesh_from(boxes)


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
