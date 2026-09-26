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
## on the origin. `tint` colours metal stock by the ore it was made from; an
## alpha of 0 means "no particular metal".
static func boxes_for(id: int, tint: Color = Color(0, 0, 0, 0)) -> Array:
	var stock := _stock_boxes(Blocks.bottom_of(id), tint)
	if not stock.is_empty():
		return stock
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
			# A loose scatter of them, each its own little grain with daylight
			# between it and the next. The last version stood them on a slab,
			# which fused the lot into one solid lump -- and seeds are the one
			# thing that is never one thing. Each lies along X or Z, a few sit
			# up on the others, and two shades keep them from reading as a
			# pattern.
			var seeds: Array = []
			var spots := [
				[Vector3(-0.20, -0.12, -0.10), true], [Vector3(-0.04, -0.12, -0.16), false],
				[Vector3(0.14, -0.12, -0.08), true], [Vector3(-0.15, -0.12, 0.08), false],
				[Vector3(0.02, -0.12, 0.03), true], [Vector3(0.19, -0.12, 0.10), false],
				[Vector3(-0.02, -0.12, 0.18), true], [Vector3(0.24, -0.12, -0.19), true],
				[Vector3(-0.26, -0.12, 0.20), true],
				# a couple resting on the ones underneath
				[Vector3(-0.06, -0.075, -0.04), false], [Vector3(0.09, -0.075, 0.07), true],
			]
			for i in spots.size():
				var at: Vector3 = spots[i][0]
				var along_x: bool = spots[i][1]
				var sz := Vector3(0.09, 0.045, 0.05) if along_x else Vector3(0.05, 0.045, 0.09)
				seeds.append([at, sz, SEED_C if i % 3 != 1 else GRAIN_DK])
				# A pale tip at one end, the way a real seed has a germ.
				var tip := Vector3(0.04, 0.0, 0.0) if along_x else Vector3(0.0, 0.0, 0.04)
				seeds.append([at + tip, Vector3(0.025, 0.05, 0.03) if along_x
					else Vector3(0.03, 0.05, 0.025), GRAIN])
			return seeds
		Blocks.FUEL_ROD:
			# A sealed rod: a banded casing with a window near the top that is
			# the only bright thing on it.
			const CASING := Color(0.38, 0.42, 0.40)
			const BAND := Color(0.26, 0.29, 0.28)
			const CORE := Color(0.45, 0.92, 0.48)
			var rod: Array = [
				[Vector3(0, 0, 0), Vector3(0.16, 0.62, 0.16), CASING],
				[Vector3(0, 0.34, 0), Vector3(0.20, 0.08, 0.20), BAND],
				[Vector3(0, -0.34, 0), Vector3(0.20, 0.08, 0.20), BAND],
				[Vector3(0, 0.10, -0.09), Vector3(0.07, 0.20, 0.02), CORE],
			]
			for i in 2:
				rod.append([Vector3(0, -0.12 + float(i) * 0.24, 0),
					Vector3(0.18, 0.04, 0.18), BAND])
			return rod
		Blocks.SOLAR_PANEL:
			# A dark cell behind glass, with a bright bus bar down the middle
			# and a tab at one corner -- small, flat, and obviously a part of
			# something rather than a thing in itself.
			const BACK := Color(0.22, 0.24, 0.28)
			const GLASSY := Color(0.17, 0.23, 0.40)
			const BUS := Color(0.62, 0.68, 0.78)
			var panel: Array = [
				[Vector3(0, -0.04, 0), Vector3(0.52, 0.05, 0.40), BACK],
				[Vector3(0, 0.00, 0), Vector3(0.48, 0.04, 0.36), GLASSY],
				[Vector3(0, 0.02, 0), Vector3(0.46, 0.01, 0.03), BUS],
				[Vector3(0.28, -0.03, 0.16), Vector3(0.08, 0.03, 0.06), BUS],
			]
			for i in 3:
				panel.append([Vector3(-0.15 + float(i) * 0.15, 0.021, 0),
					Vector3(0.015, 0.01, 0.34), BUS])
			return panel
		Blocks.COAL:
			# A baked lump: angular, matte, catching light only on its facets.
			# Deliberately nothing like an ingot, because the whole point of it
			# is that it is not one.
			const CHAR := Color(0.13, 0.12, 0.13)
			const FACET := Color(0.22, 0.21, 0.22)
			const DUST := Color(0.09, 0.08, 0.09)
			return [
				[Vector3(0, 0, 0), Vector3(0.40, 0.32, 0.36), CHAR],
				[Vector3(-0.14, 0.10, 0.06), Vector3(0.22, 0.18, 0.22), FACET],
				[Vector3(0.15, -0.04, -0.08), Vector3(0.20, 0.20, 0.18), FACET],
				[Vector3(0.08, 0.14, 0.10), Vector3(0.14, 0.12, 0.14), CHAR],
				[Vector3(-0.18, -0.10, -0.10), Vector3(0.12, 0.10, 0.12), DUST],
				[Vector3(0.20, 0.12, 0.02), Vector3(0.10, 0.09, 0.10), DUST],
			]
		Blocks.BONE:
			return [
				[Vector3(0, 0, 0), Vector3(0.52, 0.10, 0.10), BONE_C],
				[Vector3(-0.28, 0.05, 0), Vector3(0.12, 0.20, 0.16), BONE_C],
				[Vector3(0.28, 0.05, 0), Vector3(0.12, 0.20, 0.16), BONE_C],
			]
		Blocks.JOURNAL:
			# Shut, for the icon: the back half, and the front half folded over
			# onto it, written out as plain boxes.
			var shut: Array = [
				[Vector3(0, 0, 0), Vector3(0.05, PAGE_T + COVER_T * 2.0, BOOK_L), SPINE],
			]
			for b in book_half_boxes():
				var c: Vector3 = b[0]
				shut.append([c, b[1], b[2]])
				shut.append([Vector3(c.x, -c.y + COVER_T + PAGE_T, c.z), b[1], b[2]])
			return shut
		Blocks.WARP_COIL:
			# An iron core wound thick with glowing wire, capped at both ends.
			var coil: Array = [
				[Vector3(0, 0, 0), Vector3(0.16, 0.66, 0.16), Color(0.3, 0.31, 0.34)],
				[Vector3(0, 0.3, 0), Vector3(0.36, 0.06, 0.36), Color(0.5, 0.52, 0.56)],
				[Vector3(0, -0.3, 0), Vector3(0.36, 0.06, 0.36), Color(0.5, 0.52, 0.56)],
			]
			for i in 5:
				coil.append([Vector3(0, -0.2 + float(i) * 0.1, 0), Vector3(0.3, 0.06, 0.3),
					Color(0.35, 0.85, 1.0) if i % 2 == 0 else Color(0.22, 0.6, 0.8)])
			return coil
		Blocks.IGNITION_CHARGE:
			# A squat canister, a hot band round its middle and a fuse on top.
			return [
				[Vector3(0, -0.02, 0), Vector3(0.36, 0.46, 0.36), Color(0.28, 0.27, 0.27)],
				[Vector3(0, 0.02, 0), Vector3(0.38, 0.1, 0.38), Color(0.95, 0.42, 0.12)],
				[Vector3(0, 0.24, 0), Vector3(0.26, 0.04, 0.26), Color(0.5, 0.48, 0.46)],
				[Vector3(0, 0.3, 0), Vector3(0.06, 0.1, 0.06), Color(0.95, 0.75, 0.3)],
			]
		Blocks.COOLANT_JACKET:
			# A sleeve of frosted glass in a metal frame, rimed at the ends.
			var jack: Array = []
			for sx in [-1, 1]:
				jack.append([Vector3(sx * 0.17, 0, 0), Vector3(0.04, 0.5, 0.38), Color(0.75, 0.9, 1.0, 0.85)])
				jack.append([Vector3(0, 0, sx * 0.17), Vector3(0.38, 0.5, 0.04), Color(0.65, 0.85, 1.0, 0.85)])
			for sy in [-1, 1]:
				jack.append([Vector3(0, sy * 0.26, 0), Vector3(0.42, 0.06, 0.42), Color(0.92, 0.96, 1.0)])
			jack.append([Vector3(0, 0, 0), Vector3(0.14, 0.44, 0.14), Color(0.4, 0.55, 0.7)])
			return jack
		Blocks.CONTAINMENT_SHELL:
			# A heavy round shell in three courses, banded and bolted.
			var dark := Color(0.34, 0.3, 0.28)
			return [
				[Vector3(0, 0, 0), Vector3(0.5, 0.3, 0.5), dark],
				[Vector3(0, 0.2, 0), Vector3(0.36, 0.12, 0.36), dark.lightened(0.08)],
				[Vector3(0, -0.2, 0), Vector3(0.36, 0.12, 0.36), dark.lightened(0.08)],
				[Vector3(0, 0, 0), Vector3(0.54, 0.06, 0.54), Color(0.55, 0.5, 0.45)],
				[Vector3(0, 0.28, 0), Vector3(0.12, 0.04, 0.12), Color(0.2, 0.18, 0.17)],
			]
		_:
			return []


## Metal stock -- what the smelter pours and the anvil beats it into -- as the
## shape it actually is: a cast ingot, a long bar, a thin sheet, a crumpled
## heap of scrap. Coloured by its ore, pulled toward grey so it reads as metal
## rather than as paint.
static func _stock_boxes(b: int, tint: Color) -> Array:
	var is_ingot := Blocks.is_refined(b)
	if not (is_ingot or b == Blocks.BAR or b == Blocks.SHEET or b == Blocks.SCRAP
			or b == Blocks.PLATE):
		return []
	var base := Color(0.64, 0.64, 0.66)
	var c: Color = base.lerp(Color(tint.r, tint.g, tint.b), 0.55) if tint.a > 0.0 else base
	var hi: Color = c.lightened(0.18)
	var lo: Color = c.darkened(0.25)
	if is_ingot:
		return [[Vector3(0, -0.04, 0), Vector3(0.62, 0.2, 0.32), c],
			[Vector3(0, 0.08, 0), Vector3(0.52, 0.05, 0.24), hi]]
	if b == Blocks.BAR:
		return [[Vector3(0, 0, 0), Vector3(0.8, 0.11, 0.12), c],
			[Vector3(0, 0.06, 0), Vector3(0.78, 0.01, 0.08), hi]]
	if b == Blocks.PLATE:
		# Thicker than a sheet, square, with a raised rim along two edges --
		# the same look it has on the anvil when it is done.
		return [[Vector3(0, 0, 0), Vector3(0.6, 0.09, 0.6), c],
			[Vector3(0, 0.05, -0.27), Vector3(0.6, 0.02, 0.05), hi],
			[Vector3(0, 0.05, 0.27), Vector3(0.6, 0.02, 0.05), hi]]
	if b == Blocks.SHEET:
		return [[Vector3(0, 0, 0), Vector3(0.66, 0.04, 0.5), c],
			[Vector3(0.2, 0.021, 0.12), Vector3(0.2, 0.004, 0.18), hi]]
	var d: Color = c.darkened(0.35)
	return [[Vector3(-0.12, -0.05, -0.06), Vector3(0.3, 0.08, 0.2), d],
		[Vector3(0.14, 0.0, 0.06), Vector3(0.22, 0.16, 0.22), lo],
		[Vector3(-0.02, 0.07, 0.1), Vector3(0.16, 0.05, 0.26), d],
		[Vector3(0.2, -0.06, -0.14), Vector3(0.12, 0.05, 0.1), lo]]


## A book. Shut it is a slab: two covers with a block of pages between them and
## a spine down one edge. Open, the covers swing off that spine.
##
## The halves come back already placed, so anything that wants a book at a
## given openness -- the icon, the hand, the reading animation -- asks for one
## rather than working out its own hinge.
const BOOK_W := 0.30      # how far a cover reaches from the spine
const BOOK_L := 0.38      # along the spine
const COVER_T := 0.035
const PAGE_T := 0.055


## One half of a book -- a cover with its block of pages -- reaching out from a
## hinge at the origin along +X. Two of these, one turned over onto the other,
## make a shut book; swung apart they make an open one.
## `flip` puts the pages UNDER the cover instead of on top of it, which is what
## the front half needs: shut, its pages face down onto the back half; swung
## open, the same half is upside down and its pages face up. One mirrored half
## is the whole trick to a hinge that reads as a book.
static func book_half_boxes(flip := false) -> Array:
	var sgn: float = -1.0 if flip else 1.0
	return [
		[Vector3(BOOK_W * 0.5, 0, 0), Vector3(BOOK_W, COVER_T, BOOK_L), COVER],
		[Vector3(BOOK_W * 0.52, sgn * (COVER_T * 0.5 + PAGE_T * 0.5), 0),
			Vector3(BOOK_W * 0.92, PAGE_T, BOOK_L - 0.05), PAGES],
	]


## A book as a real object with a real hinge: a spine, and two halves that turn
## on it. Shut, one half is folded over onto the other; open, they lie out to
## either side. Boxes cannot rotate, so the halves are NODES -- which is what
## makes the opening read as a book opening rather than as parts sliding about.
##
## `set_book_open` moves it. Nothing else has to know how it is put together.
static func make_book() -> Node3D:
	var root := Node3D.new()
	var spine := MeshInstance3D.new()
	spine.mesh = _mesh([[Vector3.ZERO, Vector3(0.05, PAGE_T + COVER_T * 2.0, BOOK_L),
		SPINE]], false)
	spine.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
	root.add_child(spine)
	for i in 2:
		var hinge := Node3D.new()
		hinge.name = "half%d" % i
		root.add_child(hinge)
		var mi := MeshInstance3D.new()
		mi.mesh = _mesh(book_half_boxes(i == 1), false)
		mi.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
		hinge.add_child(mi)
	return root


## 0 shut, 1 open flat.
##
## Both halves hang off the spine, which runs along Z, so the hinge is a turn
## about Z and nothing else. The back half never moves: it lies out along +X
## with its pages up, which is the page you are reading. The front half is the
## mirrored one, and it swings the whole half-turn from lying on top of the
## back (shut) round through straight up to lying out the other side (open).
##
## This used to run the other way -- PI at nothing open, 0 at fully open -- so
## a shut book was drawn splayed out and opening it folded the covers together.
## That is why it never looked anything like a book opening: it was closing.
static func set_book_open(book: Node3D, open: float) -> void:
	if book == null or not is_instance_valid(book):
		return
	var k := clampf(open, 0.0, 1.0)
	var back := book.get_node_or_null("half0") as Node3D
	var front := book.get_node_or_null("half1") as Node3D
	if back == null or front == null:
		return
	back.rotation = Vector3.ZERO
	back.position = Vector3.ZERO
	# 0 shut (over the back half), PI open (out the far side). A little past
	# halfway it is standing straight up, which is exactly where a real cover
	# is when it is halfway open.
	front.rotation = Vector3(0, 0, PI * k)
	# Shut, it rests ON the back half rather than inside it; open, they are
	# level and the book lies flat.
	front.position = Vector3(0, (COVER_T + PAGE_T) * (1.0 - k), 0)


## The model shrunk into the unit cube ItemIcon photographs, with the face
## shading baked in -- an icon has no sun on it.
static func icon_mesh(id: int, tint: Color = Color(0, 0, 0, 0)) -> ArrayMesh:
	return _mesh(boxes_for(id, tint), true)


## The model as it is held or shown in the world, lit by the world.
static func mesh(id: int, tint: Color = Color(0, 0, 0, 0)) -> ArrayMesh:
	return _mesh(boxes_for(id, tint), false)


## How many bites it takes to finish something.
const BITES := 4


## The model with `eaten` of it gone: the same boxes, clipped back from the end
## you are biting, so the thing in your hand visibly shrinks as you work at it
## instead of sitting there whole until it vanishes.
##
## It eats from -X, which on the two meats is the flesh end -- so a chop is
## chewed down to the bone rather than the bone being chewed off the chop.
static func mesh_bitten(id: int, eaten: float) -> ArrayMesh:
	var boxes := boxes_for(id)
	var e := clampf(eaten, 0.0, 1.0)
	if boxes.is_empty() or e <= 0.0:
		return _mesh(boxes, false)
	var lo := 1e9
	var hi := -1e9
	for b in boxes:
		lo = minf(lo, (b[0] as Vector3).x - (b[1] as Vector3).x * 0.5)
		hi = maxf(hi, (b[0] as Vector3).x + (b[1] as Vector3).x * 0.5)
	var kept: Array = []
	for i in boxes.size():
		var b2: Array = boxes[i]
		var c: Vector3 = b2[0]
		var sz: Vector3 = b2[1]
		# A little per-box wobble in where the bite lands, so the edge is ragged
		# rather than a clean saw cut through the middle of a sandwich.
		var jit: float = (fmod(float(i) * 0.6180339887, 1.0) - 0.5) * 0.09
		var cut: float = lerpf(lo, hi + 0.02, e) + jit * (hi - lo)
		var x0: float = c.x - sz.x * 0.5
		var x1: float = c.x + sz.x * 0.5
		if x1 <= cut:
			continue
		if x0 < cut:
			var w: float = x1 - cut
			kept.append([Vector3(cut + w * 0.5, c.y, c.z), Vector3(w, sz.y, sz.z), b2[2]])
		else:
			kept.append(b2)
	return _mesh(kept, false)


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
