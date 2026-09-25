class_name ItemModels
extends RefCounted
## Little box models for the things that are neither blocks nor tools.
##
## Food and the journal had nothing to be drawn from, so the inventory fell back
## to a flat colour square and the hand held a tinted cube. Everything else in
## this game is built out of boxes -- the seat, the console, the stations, the
## boat -- so these are too, and the same models serve the icon, the hand and
## anything else that wants to show one.

const MEAT := Color(0.70, 0.26, 0.26)
const MEAT_FAT := Color(0.88, 0.72, 0.66)
const COOKED := Color(0.52, 0.31, 0.16)
const CRUST := Color(0.38, 0.21, 0.10)
const BONE_C := Color(0.90, 0.88, 0.80)
const GRAIN := Color(0.84, 0.71, 0.34)
const GRAIN_DK := Color(0.64, 0.51, 0.22)
const LOAF := Color(0.78, 0.58, 0.30)
const SEED_C := Color(0.58, 0.48, 0.26)
const COVER := Color(0.34, 0.22, 0.30)
const PAGES := Color(0.90, 0.87, 0.78)
const SPINE := Color(0.24, 0.15, 0.22)


## Is there a model for this item?
static func has_model(id: int) -> bool:
	return not boxes_for(id).is_empty()


## The model, as [centre, size, colour] boxes in a roughly 1x1x1 space centred
## on the origin.
static func boxes_for(id: int) -> Array:
	match Blocks.bottom_of(id):
		Blocks.RAW_MEAT:
			# A cut of meat on the bone: a thick wedge with fat marbled across
			# the top and a bone end sticking out of one side.
			return [
				[Vector3(0, 0, 0), Vector3(0.62, 0.30, 0.46), MEAT],
				[Vector3(0, 0.17, 0), Vector3(0.50, 0.08, 0.36), MEAT_FAT],
				[Vector3(-0.06, 0.20, 0.10), Vector3(0.26, 0.05, 0.10), MEAT_FAT],
				[Vector3(0.40, 0.02, 0), Vector3(0.22, 0.12, 0.12), BONE_C],
				[Vector3(0.52, 0.02, 0), Vector3(0.10, 0.20, 0.18), BONE_C],
			]
		Blocks.COOKED_MEAT:
			# The same cut, browned: darker, a crust on it, and shrunk a little
			# the way meat does.
			return [
				[Vector3(0, 0, 0), Vector3(0.58, 0.28, 0.42), COOKED],
				[Vector3(0, 0.15, 0), Vector3(0.50, 0.07, 0.34), CRUST],
				[Vector3(0, -0.15, 0), Vector3(0.50, 0.06, 0.34), CRUST],
				[Vector3(0.38, 0.02, 0), Vector3(0.22, 0.11, 0.11), BONE_C],
				[Vector3(0.50, 0.02, 0), Vector3(0.10, 0.19, 0.17), BONE_C],
			]
		Blocks.CROP:
			# A bundle of stalks tied in the middle, heads up.
			var out: Array = []
			for i in 5:
				var dx: float = (float(i) - 2.0) * 0.09
				var lean: float = dx * 0.35
				out.append([Vector3(dx, -0.04, lean), Vector3(0.05, 0.52, 0.05), GRAIN_DK])
				out.append([Vector3(dx * 1.25, 0.28, lean * 1.25),
					Vector3(0.11, 0.20, 0.09), GRAIN])
			out.append([Vector3(0, -0.06, 0), Vector3(0.46, 0.07, 0.16), GRAIN_DK])
			return out
		Blocks.COOKED_CROP:
			# A small loaf, scored across the top.
			var loaf: Array = [
				[Vector3(0, 0, 0), Vector3(0.56, 0.26, 0.34), LOAF],
				[Vector3(0, 0.15, 0), Vector3(0.48, 0.08, 0.28), CRUST],
			]
			for i2 in 3:
				loaf.append([Vector3(-0.14 + float(i2) * 0.14, 0.20, 0),
					Vector3(0.04, 0.05, 0.22), CRUST])
			return loaf
		Blocks.SEEDS:
			# A pinch of them, heaped.
			var seeds: Array = [
				[Vector3(0, -0.10, 0), Vector3(0.42, 0.08, 0.30), GRAIN_DK],
			]
			var spots := [Vector3(-0.10, -0.02, 0.05), Vector3(0.06, -0.02, -0.06),
				Vector3(0.12, -0.03, 0.08), Vector3(-0.04, 0.03, -0.02),
				Vector3(0.0, -0.01, 0.10)]
			for sp in spots:
				seeds.append([sp as Vector3, Vector3(0.10, 0.07, 0.07), SEED_C])
			return seeds
		Blocks.BONE:
			return [
				[Vector3(0, 0, 0), Vector3(0.52, 0.10, 0.10), BONE_C],
				[Vector3(-0.28, 0.05, 0), Vector3(0.12, 0.20, 0.16), BONE_C],
				[Vector3(0.28, 0.05, 0), Vector3(0.12, 0.20, 0.16), BONE_C],
			]
		Blocks.JOURNAL:
			return book_boxes(0.0)
		_:
			return []


## A book, `open` from 0 (shut) to 1 (open flat). Shut it is a slab with a
## spine; open it is two leaves hinged along the middle with the block of pages
## showing between them.
##
## The halves are returned already placed, so anything that wants a book at a
## given openness -- the icon, the hand, the reading animation -- asks for one
## rather than working out its own hinge.
static func book_boxes(open: float) -> Array:
	var k := clampf(open, 0.0, 1.0)
	var lift: float = k * 0.30        # how far each cover has swung up and out
	var tilt: float = k * 0.10        # and how far the pages fan
	var out: Array = [
		# Spine, which stays put whatever the covers do.
		[Vector3(0, -0.02 - k * 0.04, 0), Vector3(0.10, 0.34, 0.44), SPINE],
	]
	for sx in [-1.0, 1.0]:
		var x: float = sx * (0.16 + lift)
		var y: float = -0.02 + k * 0.10
		out.append([Vector3(x, y, 0), Vector3(0.24 + lift * 0.5, 0.05, 0.42), COVER])
		out.append([Vector3(x, y + 0.045 + tilt, 0),
			Vector3(0.21 + lift * 0.5, 0.04, 0.38), PAGES])
	return out


## The model shrunk into the unit cube ItemIcon photographs, with the face
## shading baked in -- an icon has no sun on it.
static func icon_mesh(id: int) -> ArrayMesh:
	return _mesh(boxes_for(id), true)


## The model as it is held or shown in the world, lit by the world.
static func mesh(id: int) -> ArrayMesh:
	return _mesh(boxes_for(id), false)


## A book at a given openness, for the reading animation.
static func book_mesh(open: float) -> ArrayMesh:
	return _mesh(book_boxes(open), false)


static func _mesh(boxes: Array, for_icon: bool) -> ArrayMesh:
	if boxes.is_empty():
		return null
	var lo := Vector3(1e9, 1e9, 1e9)
	var hi := -lo
	for b in boxes:
		lo = lo.min((b[0] as Vector3) - (b[1] as Vector3) * 0.5)
		hi = hi.max((b[0] as Vector3) + (b[1] as Vector3) * 0.5)
	var sc := 1.0
	var shift := Vector3.ZERO
	if for_icon:
		var ext := hi - lo
		sc = 1.0 / maxf(maxf(ext.x, ext.y), maxf(ext.z, 0.001))
		shift = -(lo + hi) * 0.5
	var st := SurfaceTool.new()
	st.begin(Mesh.PRIMITIVE_TRIANGLES)
	for b in boxes:
		var c: Color = b[2]
		var p0: Vector3 = ((b[0] as Vector3) + shift - (b[1] as Vector3) * 0.5) * sc
		var p1: Vector3 = ((b[0] as Vector3) + shift + (b[1] as Vector3) * 0.5) * sc
		for fi in 6:
			var col := c
			if for_icon:
				var shade := Chunk._face_shade(fi / 2, 1 if (fi % 2) == 0 else -1)
				col = Color(c.r * shade, c.g * shade, c.b * shade, c.a)
			st.set_color(col)
			st.set_normal(Vector3(Chunk._WFACE[fi]))
			var q := Chunk._box_face(p0, p1, fi)
			st.add_vertex(q[0]); st.add_vertex(q[2]); st.add_vertex(q[1])
			st.add_vertex(q[0]); st.add_vertex(q[3]); st.add_vertex(q[2])
	var m := st.commit()
	if m.get_surface_count() > 0:
		var mat := StandardMaterial3D.new()
		mat.vertex_color_use_as_albedo = true
		mat.roughness = 0.85
		m.surface_set_material(0, mat)
	return m
