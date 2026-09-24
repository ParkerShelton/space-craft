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
			return [
				[Vector3(0, 0.28, 0), Vector3(0.84, 0.56, 0.7), WOOD],
				[Vector3(0, 0.62, 0), Vector3(0.88, 0.16, 0.74), DARK_WOOD],
				[Vector3(0, 0.44, -0.37), Vector3(0.18, 0.18, 0.06), METAL]]
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
	var lo := Vector3(1e9, 1e9, 1e9)
	var hi := -lo
	for b in boxes_for(kind):
		lo = lo.min((b[0] as Vector3) - (b[1] as Vector3) * 0.5)
		hi = hi.max((b[0] as Vector3) + (b[1] as Vector3) * 0.5)
	var ext := hi - lo
	var sc := 1.0 / maxf(maxf(ext.x, ext.y), maxf(ext.z, 0.001))
	var shift := -(lo + hi) * 0.5
	var st := SurfaceTool.new()
	st.begin(Mesh.PRIMITIVE_TRIANGLES)
	for b in boxes_for(kind):
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
## One cell wide: a plinth, two jaws either side of a slot, and contacts at the
## back. With a battery in it the slot is FULL and a bar runs up the side of the
## cell showing what is left in it -- so you can tell across the room whether
## the ship has power, and how much, without opening anything.
static func power_bay_boxes(has_battery: bool, charge: float) -> Array:
	const CASE := Color(0.30, 0.33, 0.37)
	const DEEP := Color(0.15, 0.17, 0.20)
	const CONT := Color(0.72, 0.60, 0.28)   # contacts
	const CELL := Color(0.34, 0.40, 0.30)   # the battery's own casing
	const TRACK := Color(0.10, 0.11, 0.13)  # the empty part of the gauge
	var out: Array = [
		[Vector3(0, 0.08, 0), Vector3(0.92, 0.16, 0.86), DEEP],     # plinth
		[Vector3(-0.37, 0.46, 0), Vector3(0.18, 0.60, 0.80), CASE],  # left jaw
		[Vector3(0.37, 0.46, 0), Vector3(0.18, 0.60, 0.80), CASE],   # right jaw
		[Vector3(0, 0.46, 0.34), Vector3(0.60, 0.60, 0.14), CASE],   # back plate
		[Vector3(0, 0.82, 0), Vector3(0.92, 0.10, 0.86), DEEP],      # yoke over the top
		[Vector3(0, 0.30, 0.26), Vector3(0.30, 0.06, 0.06), CONT],   # contact bar
	]
	if not has_battery:
		# Empty: you can see straight into the slot, and the contacts with it.
		out.append([Vector3(0, 0.20, -0.02), Vector3(0.56, 0.06, 0.66), DEEP])
		out.append([Vector3(0, 0.56, 0.24), Vector3(0.10, 0.10, 0.04), CONT])
		return out
	# The battery, seated: a block with a cap, and a gauge down its face.
	var f := clampf(charge, 0.0, 1.0)
	out.append([Vector3(0, 0.48, -0.02), Vector3(0.52, 0.58, 0.62), CELL])
	out.append([Vector3(0, 0.79, -0.02), Vector3(0.44, 0.06, 0.52), DEEP])
	out.append([Vector3(0, 0.84, 0.10), Vector3(0.14, 0.06, 0.12), CONT])   # terminal
	# The gauge: a dark track the full height of the cell with the charge drawn
	# up it. It is a box of its own rather than a stripe on the casing so that
	# an empty battery reads as empty rather than as unlit.
	out.append([Vector3(GX, (G0 + G1) * 0.5, -0.34), Vector3(0.18, G1 - G0, 0.05), TRACK])
	# A label plate on the other side of the face, so the gauge is plainly a
	# gauge ON something rather than the whole front of it.
	out.append([Vector3(0.11, 0.48, -0.34), Vector3(0.20, 0.34, 0.04), DEEP])
	return out


## Where the gauge is drawn on a seated battery, shared by the casing (which
## draws the empty track) and the lit surface (which draws the charge in it).
const G0 := 0.26
const G1 := 0.70
const GX := -0.15   # off to one side, so the battery still reads as a battery


## The part of the cradle that is its own light: the charge in the gauge, and
## the contact lamp when there is nothing seated. Unshaded, so it reads the
## same in a dark cabin as it does outside in the sun -- an indicator that goes
## dim when the room does is not an indicator.
static func power_bay_lit(has_battery: bool, charge: float) -> Array:
	if not has_battery:
		return []
	var f := clampf(charge, 0.0, 1.0)
	if f <= 0.001:
		return []
	var h: float = (G1 - G0) * f
	return [[Vector3(GX, G0 + h * 0.5, -0.355), Vector3(0.14, h, 0.04), gauge_colour(f)]]


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
