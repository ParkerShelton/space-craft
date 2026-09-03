class_name Chunk
extends StaticBody3D

## One 16^3 slab of a planet. The heavy work -- greedy meshing -- is a static,
## thread-safe pure function (build_mesh_data) that touches no scene state, so it
## can run on a WorkerThreadPool. The main thread then calls apply_mesh_data to
## turn the raw arrays into an ArrayMesh + collision shape.

const CS := Blocks.CHUNK_SIZE
## Block ids are packed into UV as id/ID_SCALE; the shader multiplies back out.
const ID_SCALE := 64.0
## Marker id for the small ore lumps that protrude from an ore block's exposed
## faces. Not a real block -- it just tells the shader to draw that geometry
## with its own (ore) vertex colour instead of the smooth stone treatment the
## ore BLOCK gets.
const ORE_CHUNK_ID := 63

var planet: Planet
var cc: Vector3i  # chunk coordinate (in chunk units)

var _mesh_instance: MeshInstance3D
var _collision: CollisionShape3D
var _collision_sig := 0  # hash of the opaque verts the current shape was cooked from

## Block texturing is per PLANET, not shared: each planet seeds its own
## patterns, so one world's trees are visibly a different species from
## another's. Cached on the planet itself (see _get_material).
static var _tex_seed := 0.0
static var _shader: Shader


static var _water_material: StandardMaterial3D

## Plain vertex-colour material, for geometry that is not planet terrain --
## ships are player-built hulls (metal/cockpit/thruster), carry no block-id UVs,
## and belong to no planet, so they keep the original flat-colour look.
static var _plain_material: StandardMaterial3D

static func _get_plain_material() -> StandardMaterial3D:
	if _plain_material == null:
		_plain_material = StandardMaterial3D.new()
		_plain_material.vertex_color_use_as_albedo = true
		_plain_material.cull_mode = BaseMaterial3D.CULL_DISABLED
		_plain_material.roughness = 0.85
		_plain_material.metallic = 0.0
	return _plain_material


static func _get_material(p: Planet) -> ShaderMaterial:
	if p == null:
		return null
	if p.block_material != null:
		return p.block_material
	if _shader == null:
		_shader = load("res://shaders/voxel_block.gdshader")
	var m := ShaderMaterial.new()
	m.shader = _shader
	# The shader keeps doing what vertex_color_use_as_albedo did (COLOR is the
	# base albedo, and already carries the baked per-face shading) and layers
	# world-space procedural detail on top. cull_disabled and the
	# roughness/metallic values live in the shader itself now.
	m.set_shader_parameter("grass_id", float(Blocks.GRASS))
	m.set_shader_parameter("dirt_id", float(Blocks.DIRT))
	m.set_shader_parameter("wood_lo", float(Blocks.WOOD_IDS.min()))
	m.set_shader_parameter("wood_hi", float(Blocks.WOOD_IDS.max()))
	m.set_shader_parameter("leaf_lo", float(Blocks.LEAF_IDS.min()))
	m.set_shader_parameter("leaf_hi", float(Blocks.LEAF_IDS.max()))
	# Per-planet seed AND centre: the centre is what lets wood grain run along
	# the local up (i.e. along a trunk), which on a sphere is not world Y.
	var oids := PackedFloat32Array()
	for oid in Blocks.ORE_SLOT_IDS:
		oids.append(float(oid))
	m.set_shader_parameter("ore_ids", oids)
	m.set_shader_parameter("ore_chunk_id", ORE_CHUNK_ID)
	m.set_shader_parameter("rock_id", float(Blocks.ROCK))
	m.set_shader_parameter("world_seed", _tex_seed + float(p._seed % 9973) * 0.017)
	m.set_shader_parameter("planet_center", p.global_position)
	p.block_material = m
	return m


## Re-rolls procedural block texturing for a new world. Planets mix this with
## their own seed, so worlds differ AND planets within a world differ.
static func set_texture_seed(world_seed: int) -> void:
	_tex_seed = float(world_seed % 100000) * 0.013


static func _get_water_material() -> StandardMaterial3D:
	if _water_material == null:
		_water_material = StandardMaterial3D.new()
		_water_material.vertex_color_use_as_albedo = true  # water color carries alpha 0.55
		_water_material.transparency = BaseMaterial3D.TRANSPARENCY_ALPHA
		_water_material.cull_mode = BaseMaterial3D.CULL_DISABLED
		_water_material.roughness = 0.12
		_water_material.metallic = 0.1
	return _water_material


func _ensure_children() -> void:
	if _mesh_instance == null:
		_mesh_instance = MeshInstance3D.new()
		add_child(_mesh_instance)
	if _collision == null:
		_collision = CollisionShape3D.new()
		add_child(_collision)


func _ready() -> void:
	_ensure_children()


# --- main thread: turn raw arrays into a mesh + collision ----------------------

func apply_mesh_data(data: Dictionary) -> void:
	_ensure_children()
	var verts: PackedVector3Array = data["verts"]
	var wverts: PackedVector3Array = data["wverts"]
	if verts.is_empty() and wverts.is_empty():
		_mesh_instance.mesh = null
		_collision.shape = null
		_collision_sig = 0
		return

	var m := ArrayMesh.new()
	if not verts.is_empty():
		var arr := []
		arr.resize(Mesh.ARRAY_MAX)
		arr[Mesh.ARRAY_VERTEX] = verts
		arr[Mesh.ARRAY_NORMAL] = data["normals"]
		arr[Mesh.ARRAY_COLOR] = data["colors"]
		arr[Mesh.ARRAY_TEX_UV] = data["uvs"]
		m.add_surface_from_arrays(Mesh.PRIMITIVE_TRIANGLES, arr)
		m.surface_set_material(m.get_surface_count() - 1, _get_material(planet))
	if not wverts.is_empty():
		var warr := []
		warr.resize(Mesh.ARRAY_MAX)
		warr[Mesh.ARRAY_VERTEX] = wverts
		warr[Mesh.ARRAY_NORMAL] = data["wnormals"]
		warr[Mesh.ARRAY_COLOR] = data["wcolors"]
		m.add_surface_from_arrays(Mesh.PRIMITIVE_TRIANGLES, warr)
		m.surface_set_material(m.get_surface_count() - 1, _get_water_material())
	_mesh_instance.mesh = m
	_mesh_instance.material_override = null

	# Collision uses the COLLIDABLE opaque geometry: you pass through water, and
	# through leaves (which render but are deliberately non-solid). Cooking a
	# ConcavePolygonShape3D is expensive, so skip it when that geometry is
	# unchanged (e.g. a water-only remesh while a nearby lake is flowing).
	var cverts: PackedVector3Array = data.get("cverts", verts)
	if cverts.is_empty():
		_collision.shape = null
		_collision_sig = 0
	else:
		var sig := hash(cverts)
		if sig != _collision_sig or _collision.shape == null:
			var shape := ConcavePolygonShape3D.new()
			shape.backface_collision = true
			shape.set_faces(cverts)
			_collision.shape = shape
			_collision_sig = sig


# --- background thread: pure greedy mesher ------------------------------------
#
# `snap` maps Vector3i(global voxel) -> block id for any player edits in this
# chunk and its face-neighbors. Everything else comes from planet.generation_sample
# (a pure read of noise), so this function is safe to run off the main thread.

static func _id_at(planet: Planet, snap: Dictionary, v: Vector3i) -> int:
	if snap.has(v):
		return snap[v]
	return planet.generation_sample(v.x, v.y, v.z)


static func build_mesh_data(planet: Planet, cc: Vector3i, snap: Dictionary, wsnap: Dictionary = {}) -> Dictionary:
	var base := cc * CS
	var ids := PackedInt32Array()
	ids.resize(CS * CS * CS)
	var any_solid := false
	var i := 0
	for z in CS:
		for y in CS:
			for x in CS:
				var id := _id_at(planet, snap, Vector3i(base.x + x, base.y + y, base.z + z))
				ids[i] = id
				if id != Blocks.AIR and id != Blocks.DOOR_OPEN:
					any_solid = true
				i += 1

	# opaque geometry (surface 0, collidable) and water geometry (surface 1, see-through)
	var verts := PackedVector3Array()
	var normals := PackedVector3Array()
	var colors := PackedColorArray()
	var wverts := PackedVector3Array()
	var wnormals := PackedVector3Array()
	var wcolors := PackedColorArray()
	var uvs := PackedVector2Array()
	var wuvs := PackedVector2Array()
	var cverts := PackedVector3Array()  # collidable subset of `verts` (no leaves)
	if not any_solid:
		return {"verts": verts, "normals": normals, "colors": colors, "uvs": uvs,
			"cverts": cverts, "wverts": wverts, "wnormals": wnormals, "wcolors": wcolors}

	# opaque terrain via greedy meshing (water is skipped here, handled below)
	var strides := [1, CS, CS * CS]
	for d in 3:
		var u := (d + 1) % 3
		var v := (d + 2) % 3
		for dir in [1, -1]:
			_greedy_pass(planet, snap, d, u, v, dir, base, ids, strides,
				verts, normals, colors, wverts, wnormals, wcolors, uvs, wuvs, cverts)

	# water: one box per cell, its height set by the water level (shallow water
	# renders lower). Fill is along the cell's outward axis (radial-snapped).
	var wfull := float(Planet.W_FULL)
	var idx := 0
	for z in CS:
		for y in CS:
			for x in CS:
				if ids[idx] == Blocks.WATER:
					var gv := Vector3i(base.x + x, base.y + y, base.z + z)
					var level: int = wsnap.get(gv, int(wfull))
					var h := clampf(float(level) / wfull, 0.12, 1.0)
					var up := planet._axis_of(Vector3(gv) + Vector3(0.5, 0.5, 0.5))
					var lo := Vector3(x, y, z)
					var hi := Vector3(x + 1, y + 1, z + 1)
					if up.x > 0.5: hi.x = lo.x + h
					elif up.x < -0.5: lo.x = hi.x - h
					elif up.y > 0.5: hi.y = lo.y + h
					elif up.y < -0.5: lo.y = hi.y - h
					elif up.z > 0.5: hi.z = lo.z + h
					elif up.z < -0.5: lo.z = hi.z - h
					_emit_water_cell(lo, hi, gv, planet, snap, wverts, wnormals, wcolors, wuvs)
				idx += 1

	# roof slabs: a half-height OPAQUE box per cell (real geometry, not just a
	# smaller-looking color) -- same partial-height technique as water above, but
	# written into the opaque arrays so it collides and renders solid, giving
	# roofs a thinner, shingle-like edge instead of a full-cube block silhouette.
	idx = 0
	for z in CS:
		for y in CS:
			for x in CS:
				# Half-height blocks: roof slabs and every crafted material slab.
				# All share one path -- a real partial-height box, so they render
				# AND collide at half height rather than just looking short.
				var hid := ids[idx]
				if hid == Blocks.ROOF_SLAB or Blocks.is_slab(hid):
					var gv := Vector3i(base.x + x, base.y + y, base.z + z)
					var up := planet._axis_of(Vector3(gv) + Vector3(0.5, 0.5, 0.5))
					var lo := Vector3(x, y, z)
					var hi := Vector3(x + 1, y + 1, z + 1)
					var h := 0.5
					# The flat half sits on the LOCAL down side, which on a cube
					# or sphere planet is whichever axis is "up" here.
					if up.x > 0.5: hi.x = lo.x + h
					elif up.x < -0.5: lo.x = hi.x - h
					elif up.y > 0.5: hi.y = lo.y + h
					elif up.y < -0.5: lo.y = hi.y - h
					elif up.z > 0.5: hi.z = lo.z + h
					elif up.z < -0.5: lo.z = hi.z - h
					# Meshed under its MATERIAL id, so a rock slab is coloured and
					# textured exactly like rock without needing its own entries.
					_emit_solid_box_cell(lo, hi, gv, Blocks.base_material_of(hid),
						planet, snap, verts, normals, colors, uvs, cverts)
				idx += 1

	# ore lumps: decorative geometry on exposed ore faces (see _emit_ore_chunks)
	idx = 0
	for z in CS:
		for y in CS:
			for x in CS:
				if Blocks.is_ore(ids[idx]):
					_emit_ore_chunks(Vector3(x, y, z),
						Vector3i(base.x + x, base.y + y, base.z + z),
						ids[idx], planet, snap, verts, normals, colors, uvs)
				idx += 1

	return {"verts": verts, "normals": normals, "colors": colors, "uvs": uvs,
		"cverts": cverts, "wverts": wverts, "wnormals": wnormals, "wcolors": wcolors}


const _WFACE := [Vector3i(1,0,0), Vector3i(-1,0,0), Vector3i(0,1,0),
	Vector3i(0,-1,0), Vector3i(0,0,1), Vector3i(0,0,-1)]

## Stable pseudo-random in 0..1 from a voxel coord and a salt, so a given ore
## block grows the same lumps every time it is remeshed.
static func _hash3(v: Vector3i, k: int) -> float:
	var h: int = (v.x * 73856093) ^ (v.y * 19349663) ^ (v.z * 83492791) ^ (k * 2654435761)
	return float(absi(h) % 100003) / 100003.0


## A box with all six faces, unattached to the voxel grid. Deliberately NOT
## added to the collision list: these are decorative lumps a few centimetres
## proud of the wall, and making them solid would turn every ore vein into a
## surface the player snags on.
static func _emit_free_box(lo: Vector3, hi: Vector3, base_col: Color, bid: int,
		verts: PackedVector3Array, normals: PackedVector3Array,
		colors: PackedColorArray, uvs: PackedVector2Array) -> void:
	for fi in 6:
		var n: Vector3i = _WFACE[fi]
		var sh := _face_shade(fi / 2, 1 if (fi % 2) == 0 else -1)
		var col := Color(base_col.r * sh, base_col.g * sh, base_col.b * sh, base_col.a)
		var q := _box_face(lo, hi, fi)
		_quad(q[0], q[1], q[2], q[3], Vector3(n), col, verts, normals, colors, uvs, bid, sh)


## Ore lumps standing proud of an ore block's exposed faces, so a vein reads as
## chunks embedded in rock with real silhouette rather than a pattern painted
## on a flat surface. Only exposed faces grow them -- buried ore is invisible
## anyway, and skipping it keeps the extra geometry proportional to what is
## actually on screen.
static func _emit_ore_chunks(lo: Vector3, gv: Vector3i, id: int, planet: Planet,
		snap: Dictionary, verts: PackedVector3Array, normals: PackedVector3Array,
		colors: PackedColorArray, uvs: PackedVector2Array) -> void:
	var ore_col := planet.ore_color(id)
	for fi in 6:
		var n: Vector3i = _WFACE[fi]
		var nid := _id_at(planet, snap, gv + n)
		if nid != Blocks.AIR and nid != Blocks.DOOR_OPEN:
			continue
		var nv := Vector3(n)
		var t1 := Vector3(nv.y, nv.z, nv.x)   # any axis perpendicular to nv
		var t2 := nv.cross(t1)
		var face_c := lo + Vector3(0.5, 0.5, 0.5) + nv * 0.5
		var count := 1 + int(_hash3(gv, fi) * 2.99) % 2   # one or two lumps
		for k in count:
			var h1 := _hash3(gv, fi * 7 + k * 13 + 1)
			var h2 := _hash3(gv, fi * 11 + k * 29 + 2)
			var h3 := _hash3(gv, fi * 17 + k * 41 + 3)
			var sz: float = 0.085 + h3 * 0.075
			var spread: float = maxf(0.5 - sz * 2.0, 0.05)
			var c := face_c + t1 * ((h1 - 0.5) * spread * 2.0) 				+ t2 * ((h2 - 0.5) * spread * 2.0) 				- nv * (sz * 0.25)   # mostly buried: only ~0.75 of the lump shows,
				                     # so it grows OUT of the rock rather than
				                     # sitting on top of it like a dropped cube
			_emit_free_box(c - Vector3.ONE * sz, c + Vector3.ONE * sz,
				ore_col, ORE_CHUNK_ID, verts, normals, colors, uvs)


static func _emit_water_cell(lo: Vector3, hi: Vector3, gv: Vector3i, planet: Planet,
		snap: Dictionary, wverts: PackedVector3Array, wnormals: PackedVector3Array,
		wcolors: PackedColorArray, wuvs: PackedVector2Array) -> void:
	var base := Blocks.color_of(Blocks.WATER)
	for fi in 6:
		var n: Vector3i = _WFACE[fi]
		if _id_at(planet, snap, gv + n) != Blocks.AIR:
			continue  # only the faces exposed to air are drawn
		var s := _face_shade(fi / 2, 1 if (fi % 2) == 0 else -1)
		var col := Color(base.r * s, base.g * s, base.b * s, base.a)
		var nrm := Vector3(n)
		var q := _box_face(lo, hi, fi)
		_quad(q[0], q[1], q[2], q[3], nrm, col, wverts, wnormals, wcolors, wuvs, Blocks.WATER, s)


static func _emit_solid_box_cell(lo: Vector3, hi: Vector3, gv: Vector3i, id: int, planet: Planet,
		snap: Dictionary, verts: PackedVector3Array, normals: PackedVector3Array,
		colors: PackedColorArray, uvs: PackedVector2Array, cverts: PackedVector3Array) -> void:
	var base := _block_color(planet, id)
	for fi in 6:
		var n: Vector3i = _WFACE[fi]
		var nid := _id_at(planet, snap, gv + n)
		# A half-height neighbour cannot cover a full face, so it does not hide
		# one -- otherwise a slab beside a block punches a hole in the wall.
		if nid != Blocks.AIR and nid != Blocks.DOOR_OPEN and not Blocks.is_slab(nid) 				and nid != Blocks.ROOF_SLAB:
			continue  # only the faces exposed to open space are drawn
		var s := _face_shade(fi / 2, 1 if (fi % 2) == 0 else -1)
		var col := Color(base.r * s, base.g * s, base.b * s, base.a)
		var nrm := Vector3(n)
		var q := _box_face(lo, hi, fi)
		_quad(q[0], q[1], q[2], q[3], nrm, col, verts, normals, colors, uvs, id, s, cverts)


static func _box_face(lo: Vector3, hi: Vector3, fi: int) -> Array:
	match fi:
		0: return [Vector3(hi.x, lo.y, lo.z), Vector3(hi.x, hi.y, lo.z), Vector3(hi.x, hi.y, hi.z), Vector3(hi.x, lo.y, hi.z)]  # +X
		1: return [Vector3(lo.x, lo.y, lo.z), Vector3(lo.x, lo.y, hi.z), Vector3(lo.x, hi.y, hi.z), Vector3(lo.x, hi.y, lo.z)]  # -X
		2: return [Vector3(lo.x, hi.y, lo.z), Vector3(lo.x, hi.y, hi.z), Vector3(hi.x, hi.y, hi.z), Vector3(hi.x, hi.y, lo.z)]  # +Y
		3: return [Vector3(lo.x, lo.y, lo.z), Vector3(hi.x, lo.y, lo.z), Vector3(hi.x, lo.y, hi.z), Vector3(lo.x, lo.y, hi.z)]  # -Y
		4: return [Vector3(lo.x, lo.y, hi.z), Vector3(hi.x, lo.y, hi.z), Vector3(hi.x, hi.y, hi.z), Vector3(lo.x, hi.y, hi.z)]  # +Z
		_: return [Vector3(lo.x, lo.y, lo.z), Vector3(lo.x, hi.y, lo.z), Vector3(hi.x, hi.y, lo.z), Vector3(hi.x, lo.y, lo.z)]  # -Z


static func _greedy_pass(planet: Planet, snap: Dictionary, d: int, u: int, v: int, dir: int,
		base: Vector3i, ids: PackedInt32Array, strides: Array,
		verts: PackedVector3Array, normals: PackedVector3Array, colors: PackedColorArray,
		wverts: PackedVector3Array, wnormals: PackedVector3Array, wcolors: PackedColorArray,
		uvs: PackedVector2Array, wuvs: PackedVector2Array, cverts: PackedVector3Array) -> void:
	var sd: int = strides[d]
	var su: int = strides[u]
	var sv: int = strides[v]
	var narr := [0.0, 0.0, 0.0]
	narr[d] = float(dir)
	var normal := Vector3(narr[0], narr[1], narr[2])

	var mask := PackedInt32Array()
	mask.resize(CS * CS)

	for a in CS:
		for j in CS:
			var row := j * sv
			for k in CS:
				var lin := a * sd + k * su + row
				var oid := ids[lin]
				var val := 0
				# opaque blocks only; WATER and ROOF_SLAB are meshed separately as
				# partial-height boxes, and an OPEN door draws as an empty gap (no
				# face, no collision) so you can actually walk through it once opened
				if oid != Blocks.AIR and oid != Blocks.WATER and oid != Blocks.DOOR_OPEN 						and oid != Blocks.ROOF_SLAB and not Blocks.is_slab(oid):
					var na := a + dir
					var nid: int
					if na >= 0 and na < CS:
						nid = ids[na * sd + k * su + row]
					else:
						nid = _id_at(planet, snap, _global_coord(base, d, u, v, na, k, j))
					# draw a face if the neighbor is air, water, an open doorway, or a
					# roof slab (so the seabed shows under water, a room shows through
					# an open door, and a wall/ridge shows past a half-height slab)
					if nid == Blocks.AIR or nid == Blocks.WATER or nid == Blocks.DOOR_OPEN 							or nid == Blocks.ROOF_SLAB or Blocks.is_slab(nid):
						val = oid
				mask[k + j * CS] = val

		var w_coord := a + (1 if dir > 0 else 0)
		_emit_mask(planet, mask, d, u, v, dir, w_coord, normal,
			verts, normals, colors, wverts, wnormals, wcolors, uvs, wuvs, cverts)


# Opaque blocks use their registry colour, except procedural ores, whose colour is
# defined by the planet (each world's ores look different).
static func _block_color(planet: Planet, id: int) -> Color:
	# Ore blocks are meshed as STONE. The ore itself is drawn by the shader as
	# chunks embedded in that stone (colour supplied per planet via uniforms),
	# rather than the whole block being one flat ore colour.
	if Blocks.is_ore(id):
		return Blocks.color_of(planet.pal_rock)
	return Blocks.color_of(id)


static func _emit_mask(planet: Planet, mask: PackedInt32Array, d: int, u: int, v: int, dir: int, w_coord: int,
		normal: Vector3,
		verts: PackedVector3Array, normals: PackedVector3Array, colors: PackedColorArray,
		wverts: PackedVector3Array, wnormals: PackedVector3Array, wcolors: PackedColorArray,
		uvs: PackedVector2Array, wuvs: PackedVector2Array, cverts: PackedVector3Array) -> void:
	for j in CS:
		var k := 0
		while k < CS:
			var val := mask[k + j * CS]
			if val == 0:
				k += 1
				continue
			var wdt := 1
			while k + wdt < CS and mask[k + wdt + j * CS] == val:
				wdt += 1
			var hgt := 1
			var stop := false
			while j + hgt < CS and not stop:
				for x in wdt:
					if mask[k + x + (j + hgt) * CS] != val:
						stop = true
						break
				if not stop:
					hgt += 1
			for jj in hgt:
				for x in wdt:
					mask[k + x + (j + jj) * CS] = 0

			# Bake per-face directional shading into the vertex color so faces of
			# different orientation read distinctly even under flat ambient light.
			var s := _face_shade(d, dir)
			var base := _block_color(planet, val)
			var col := Color(base.r * s, base.g * s, base.b * s, base.a)  # keep alpha (water)
			var p00 := _corner(d, u, v, w_coord, k, j)
			var p10 := _corner(d, u, v, w_coord, k + wdt, j)
			var p11 := _corner(d, u, v, w_coord, k + wdt, j + hgt)
			var p01 := _corner(d, u, v, w_coord, k, j + hgt)
			if val == Blocks.WATER:
				if dir > 0:
					_quad(p00, p10, p11, p01, normal, col, wverts, wnormals, wcolors, wuvs, val, s)
				else:
					_quad(p00, p01, p11, p10, normal, col, wverts, wnormals, wcolors, wuvs, val, s)
			else:
				if dir > 0:
					_quad(p00, p10, p11, p01, normal, col, verts, normals, colors, uvs, val, s, cverts)
				else:
					_quad(p00, p01, p11, p10, normal, col, verts, normals, colors, uvs, val, s, cverts)
			k += wdt


static func _quad(a: Vector3, b: Vector3, c: Vector3, e: Vector3, normal: Vector3, col: Color,
		verts: PackedVector3Array, normals: PackedVector3Array, colors: PackedColorArray,
		uvs: PackedVector2Array, bid: int, shade: float, cverts: PackedVector3Array = PackedVector3Array()) -> void:
	verts.append(a); verts.append(b); verts.append(c)
	verts.append(a); verts.append(c); verts.append(e)
	# Leaves render but do not collide, so a canopy feels like foliage you brush
	# through. Collision therefore gets its OWN vertex list rather than reusing
	# the render mesh.
	if not Blocks.is_leaf(bid):
		cverts.append(a); cverts.append(b); cverts.append(c)
		cverts.append(a); cverts.append(c); cverts.append(e)
	for _n in 6:
		normals.append(normal)
		colors.append(col)
		# UV carries the BLOCK ID, not a texture coordinate: greedy-meshed quads
		# span arbitrary numbers of blocks, so there is no meaningful UV layout
		# to hand the shader. The pattern itself comes from world position (see
		# shaders/voxel_block.gdshader); this is only how the shader knows which
		# kind of block it is drawing.
		#
		# Scaled into 0..1 rather than stored raw. Godot compresses vertex
		# attributes, and a raw id like 16.0 came back mangled -- terrain was
		# landing inside the leaf id range and getting alpha-scissored, which
		# showed up as sky speckling through solid rock. Keeping it normalised
		# leaves plenty of resolution (ids are well under ID_SCALE).
		# UV.y carries the face's baked shade. Ore blocks draw their chunks
		# from a uniform colour rather than the vertex colour, so they need the
		# same directional shading applied to stay consistent with the face.
		uvs.append(Vector2(float(bid) / ID_SCALE, shade))


## Fake sky/directional shading by face orientation (world axes): up faces catch
## the most light, side faces less, down faces least. Cheap, greedy-friendly, and
## it stacks on top of the real directional sun.
static func _face_shade(d: int, dir: int) -> float:
	if d == 1:  # Y axis
		return 1.0 if dir > 0 else 0.5
	if d == 0:  # X axis
		return 0.78 if dir > 0 else 0.70
	return 0.86 if dir > 0 else 0.62  # Z axis


static func _corner(d: int, u: int, v: int, wc: int, uu: int, vv: int) -> Vector3:
	var p := [0.0, 0.0, 0.0]
	p[d] = float(wc)
	p[u] = float(uu)
	p[v] = float(vv)
	return Vector3(p[0], p[1], p[2])


static func _global_coord(base: Vector3i, d: int, u: int, v: int, ld: int, lu: int, lv: int) -> Vector3i:
	var l := [0, 0, 0]
	l[d] = ld
	l[u] = lu
	l[v] = lv
	return Vector3i(base.x + l[0], base.y + l[1], base.z + l[2])
