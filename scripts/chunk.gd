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
var _lights: Array = []      # OmniLight3D nodes for this chunk's light blocks
var _collision_sig := 0  # hash of the opaque verts the current shape was cooked from

## Block texturing is per PLANET, not shared: each planet seeds its own
## patterns, so one world's trees are visibly a different species from
## another's. Cached on the planet itself (see _get_material).
static var _tex_seed := 0.0
## Keys under which the light map rides along in a build's edit snapshot.
## Deliberately NOT static state: chunks mesh concurrently on worker threads, so
## a shared map would be clobbered mid-build by whichever chunk started last.
## The snapshot is created fresh per build, which makes it the natural carrier.
const LM_KEY := "__lightmap"
const LB_KEY := "__lightbase"


## Light 0..1 just outside a face -- i.e. in the open cell the face looks into,
## which is where a torch's light actually is.
static func _face_light(snap: Dictionary, gv: Vector3i, n: Vector3i) -> float:
	var lm = snap.get(LM_KEY)
	if lm == null or (lm as PackedByteArray).is_empty():
		return 0.0
	var l: Vector3i = gv + n - (snap[LB_KEY] as Vector3i) 		+ Vector3i(LIGHT_PAD, LIGHT_PAD, LIGHT_PAD)
	if l.x < 0 or l.y < 0 or l.z < 0 			or l.x >= LIGHT_DIM or l.y >= LIGHT_DIM or l.z >= LIGHT_DIM:
		return 0.0
	return float((lm as PackedByteArray)[_light_index(l.x, l.y, l.z)]) / 15.0
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
	m.set_shader_parameter("plank_lo", float(Blocks.PLANK_IDS.min()))
	m.set_shader_parameter("plank_hi", float(Blocks.PLANK_IDS.max()))
	m.set_shader_parameter("leaf_lo", float(Blocks.LEAF_IDS.min()))
	m.set_shader_parameter("leaf_hi", float(Blocks.LEAF_IDS.max()))
	# Per-planet seed AND centre: the centre is what lets wood grain run along
	# the local up (i.e. along a trunk), which on a sphere is not world Y.
	var oids := PackedFloat32Array()
	for oid in Blocks.ORE_SLOT_IDS:
		oids.append(float(oid))
	m.set_shader_parameter("ore_ids", oids)
	m.set_shader_parameter("ore_chunk_id", ORE_CHUNK_ID)
	# Foliage silhouette varies per world, so an alien canopy differs in shape
	# and density and not only in colour.
	m.set_shader_parameter("leaf_holes", p.leaf_holes)
	m.set_shader_parameter("leaf_grain", p.leaf_grain)
	m.set_shader_parameter("ground_grain", p.ground_grain)
	m.set_shader_parameter("ground_levels", p.ground_levels)
	m.set_shader_parameter("ground_contrast", p.ground_contrast)
	m.set_shader_parameter("rock_grain", p.rock_grain)
	m.set_shader_parameter("rock_contrast", p.rock_contrast)
	m.set_shader_parameter("light_lo", float(Blocks.LIGHT_IDS.min()))
	m.set_shader_parameter("light_hi", float(Blocks.LIGHT_IDS.max()))
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


## Real OmniLight3D nodes for the light blocks in this chunk. Rebuilt whenever
## the chunk re-meshes, which is also when a torch could have been placed or
## broken. Kept as children of the chunk so they stream in and out with it.
func _apply_lights(positions: PackedVector3Array) -> void:
	for l in _lights:
		if is_instance_valid(l):
			l.queue_free()
	_lights.clear()
	for p in positions:
		var om := OmniLight3D.new()
		var def := Blocks.light_def(planet.get_id(
			Vector3i(cc * CS) + Vector3i(floori(p.x), floori(p.y), floori(p.z))) if planet != null else Blocks.TORCH)
		# These now light DYNAMIC things only -- the player, creatures, dropped
		# items -- because terrain gets its light baked into the mesh instead
		# (see _compute_block_light). Godot's Compatibility renderer would not
		# light runtime ArrayMesh chunks with these at all. Kept modest so they
		# complement the baked light rather than double it.
		om.omni_range = float(def["range"]) * 0.8
		om.light_energy = float(def["energy"]) * 0.7
		om.light_color = def["color"]
		om.shadow_enabled = false   # dozens of shadow-casting lights is not worth it
		add_child(om)
		om.position = p
		_lights.append(om)


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
		arr[Mesh.ARRAY_TEX_UV2] = data["uv2s"]
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
	_apply_lights(data.get("lights", PackedVector3Array()))

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

# The greedy mask loop runs 6 x CS^3 times per chunk -- ~25k iterations -- and
# used to ask Blocks up to ten questions per iteration. In GDScript the call
# overhead dwarfed the work, and it was most of the cost of re-meshing a chunk
# after a single block edit. Every one of those questions depends only on the
# block's low byte, so they are answered once into two tables at class load.
#
#   _FULL     the block is a full opaque cube the greedy pass should mesh
#   _SEETHRU  a neighbour of this kind does NOT hide the face behind it
#
# Packed voxels (stair facing, log axis, a stacked slab's top id) keep their
# extra data in the high bytes, so indexing by `id & ID_MASK` is exact: a
# stacked slab's low byte is its bottom slab id, which is already not-full and
# see-through, matching what the per-call version decided.
## Key under which _edits_snapshot hands the mesher a thread-safe copy of the
## parts table (voxel -> PackedByteArray of eight sub-cell ids).
const PARTS_KEY := "__parts"

# Daylight fades with how deeply a face is buried. Depth ALONE, deliberately:
# earlier versions also probed upward for a roof and took the darker of the two,
# and the two signals fell off at different rates, so one cavern wall snapped to
# black while the wall beside it stayed lit. One smooth term cannot blotch.
#
# SKY_FREE is slack for voxel stepping -- blocky ground means a cliff face in
# full daylight still sits a few blocks under the smooth noise surface.
const SKY_FREE := 4.0
const SKY_FADE := 30.0

# How far below the surface daylight stops reaching, in blocks. Below this a
# face is lit only by whatever the player brought with them.

static var _FULL: PackedByteArray
static var _SEETHRU: PackedByteArray
# Leaves are see-through, so without this two adjacent leaves would EACH draw a
# face toward the other. Those quads are coplanar and, under cull_disabled, both
# render at the same depth -- z-fighting across the whole canopy. Same-material
# transparent neighbours cull each other, as in any block game.
static var _LEAF: PackedByteArray


static func _static_init() -> void:
	_FULL = PackedByteArray()
	_FULL.resize(256)
	_SEETHRU = PackedByteArray()
	_SEETHRU.resize(256)
	_LEAF = PackedByteArray()
	_LEAF.resize(256)
	for id in 256:
		var full: bool = not (id == Blocks.AIR or id == Blocks.WATER
			or id == Blocks.DOOR_OPEN or id == Blocks.ROOF_SLAB
			or Blocks.is_slab(id) or Blocks.is_stair(id) or Blocks.is_light(id)
			or Blocks.is_wire(id) or id == Blocks.PARTS)
		_FULL[id] = 1 if full else 0
		# Leaves are meshed AND see-through: they are drawn with cutout holes, so
		# they must not hide the block behind them.
		_SEETHRU[id] = 1 if (not full or Blocks.is_leaf(id)) else 0
		_LEAF[id] = 1 if Blocks.is_leaf(id) else 0


static func _id_at(planet: Planet, snap: Dictionary, v: Vector3i) -> int:
	if snap.has(v):
		return snap[v]
	return planet.generation_sample(v.x, v.y, v.z)


## Voxel light, flood-filled the way a block game does it rather than with real
## point lights.
##
## Godot's Compatibility renderer would not light these runtime ArrayMesh chunks
## with OmniLight3D at all (verified at length: a plain BoxMesh beside a torch
## lights perfectly while the terrain beside it stays black, with identical
## normals, materials, layers and instance properties). Baking the light into
## the mesh sidesteps that entirely -- and it is the better design anyway: it
## costs nothing per light, supports unlimited torches, and gives the authentic
## look of light falling off block by block and spilling around corners.
##
## Levels are 0..15 and drop by one per block travelled through anything that
## isn't solid. The region is padded so light from a torch just outside this
## chunk still reaches into it.
const LIGHT_PAD := 15
const LIGHT_DIM := CS + LIGHT_PAD * 2


static func _light_index(x: int, y: int, z: int) -> int:
	return x + y * LIGHT_DIM + z * LIGHT_DIM * LIGHT_DIM


## Returns a byte per cell of the padded region, or an empty array when there
## is no light source anywhere near -- which is the common case, and skipping
## the flood fill entirely keeps ordinary chunks as cheap as they were.
static func _compute_block_light(planet: Planet, snap: Dictionary, base: Vector3i) -> PackedByteArray:
	var origin := base - Vector3i(LIGHT_PAD, LIGHT_PAD, LIGHT_PAD)
	# Seed from the EDIT snapshot rather than scanning the padded volume: light
	# blocks are always player-placed, so the only candidates are edited cells,
	# and the snapshot already spans this chunk plus its face neighbours (far
	# enough for a level-15 light to reach in). Scanning every cell instead
	# meant ~100k terrain samples per remesh for a result that is almost always
	# empty.
	var seeds: Array = []
	for k in snap:
		if not (k is Vector3i):
			continue
		var lvl := Blocks.light_level(int(snap[k]))
		if lvl <= 0:
			continue
		var lp: Vector3i = (k as Vector3i) - origin
		if lp.x < 0 or lp.y < 0 or lp.z < 0 				or lp.x >= LIGHT_DIM or lp.y >= LIGHT_DIM or lp.z >= LIGHT_DIM:
			continue
		seeds.append([lp.x, lp.y, lp.z, lvl])
	if seeds.is_empty():
		return PackedByteArray()
	var lv := PackedByteArray()
	lv.resize(LIGHT_DIM * LIGHT_DIM * LIGHT_DIM)
	# Breadth-first by level: seed the brightest first and walk outward, so each
	# cell ends up with the strongest light that reaches it.
	var frontier: Array = []
	for sd in seeds:
		var si := _light_index(sd[0], sd[1], sd[2])
		if sd[3] > lv[si]:
			lv[si] = sd[3]
			frontier.append(Vector3i(sd[0], sd[1], sd[2]))
	var nb := [Vector3i(1,0,0), Vector3i(-1,0,0), Vector3i(0,1,0),
		Vector3i(0,-1,0), Vector3i(0,0,1), Vector3i(0,0,-1)]
	while not frontier.is_empty():
		var nxt: Array = []
		for c in frontier:
			var here: int = lv[_light_index(c.x, c.y, c.z)]
			if here <= 1:
				continue
			for d in nb:
				var n: Vector3i = c + d
				if n.x < 0 or n.y < 0 or n.z < 0 						or n.x >= LIGHT_DIM or n.y >= LIGHT_DIM or n.z >= LIGHT_DIM:
					continue
				var ni := _light_index(n.x, n.y, n.z)
				if lv[ni] >= here - 1:
					continue
				var nid := _id_at(planet, snap, origin + n)
				# Light travels through anything you can see through.
				if nid != Blocks.AIR and nid != Blocks.WATER and nid != Blocks.DOOR_OPEN 						and not Blocks.is_light(Blocks.bottom_of(nid)):
					continue
				lv[ni] = here - 1
				nxt.append(n)
		frontier = nxt
	return lv


static func build_mesh_data(planet: Planet, cc: Vector3i, snap: Dictionary, wsnap: Dictionary = {}) -> Dictionary:
	var base := cc * CS
	snap[LB_KEY] = base
	snap[LM_KEY] = _compute_block_light(planet, snap, base)
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
	var uv2s := PackedVector2Array()
	var wuv2s := PackedVector2Array()
	var cverts := PackedVector3Array()  # collidable subset of `verts` (no leaves)
	if not any_solid:
		return {"verts": verts, "normals": normals, "colors": colors, "uvs": uvs, "uv2s": uv2s, "lights": PackedVector3Array(),
			"cverts": cverts, "wverts": wverts, "wnormals": wnormals, "wcolors": wcolors}

	# opaque terrain via greedy meshing (water is skipped here, handled below)
	var strides := [1, CS, CS * CS]
	for d in 3:
		var u := (d + 1) % 3
		var v := (d + 2) % 3
		for dir in [1, -1]:
			_greedy_pass(planet, snap, d, u, v, dir, base, ids, strides,
				verts, normals, colors, wverts, wnormals, wcolors, uvs, wuvs, uv2s, wuv2s,
				cverts)

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
					_emit_water_cell(lo, hi, gv, planet, snap, wverts, wnormals, wcolors, wuvs, wuv2s)
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
				if Blocks.is_stair(Blocks.bottom_of(hid)):
					_emit_stair(Vector3(x, y, z),
						Vector3i(base.x + x, base.y + y, base.z + z), hid,
						planet, snap, verts, normals, colors, uvs, uv2s, cverts)
				elif hid == Blocks.ROOF_SLAB or Blocks.is_slab(hid) or Blocks.is_stacked_slab(hid):
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
					if Blocks.is_stacked_slab(hid):
						# Two different slabs sharing this voxel: draw each half
						# in its own material. Same-material pairs never reach
						# here -- they merge into the plain full block instead.
						var t_lo := lo
						var t_hi := hi
						if up.x > 0.5: t_lo.x = hi.x; t_hi.x = lo.x + 1.0
						elif up.x < -0.5: t_hi.x = lo.x; t_lo.x = hi.x - 1.0
						elif up.y > 0.5: t_lo.y = hi.y; t_hi.y = lo.y + 1.0
						elif up.y < -0.5: t_hi.y = lo.y; t_lo.y = hi.y - 1.0
						elif up.z > 0.5: t_lo.z = hi.z; t_hi.z = lo.z + 1.0
						elif up.z < -0.5: t_hi.z = lo.z; t_lo.z = hi.z - 1.0
						_emit_solid_box_cell(lo, hi, gv,
							Blocks.base_material_of(Blocks.bottom_of(hid)),
							planet, snap, verts, normals, colors, uvs, uv2s, cverts)
						_emit_solid_box_cell(t_lo, t_hi, gv,
							Blocks.base_material_of(Blocks.top_slab_of(hid)),
							planet, snap, verts, normals, colors, uvs, uv2s, cverts)
					else:
						_emit_solid_box_cell(lo, hi, gv, Blocks.base_material_of(hid),
							planet, snap, verts, normals, colors, uvs, uv2s, cverts)
				idx += 1

	# light blocks: a torch is a small standing post rather than a full cube, and
	# both are recorded so the chunk can hang real lights on them below.
	var lights := PackedVector3Array()
	idx = 0
	for z in CS:
		for y in CS:
			for x in CS:
				var lid := ids[idx]
				if Blocks.is_light(Blocks.bottom_of(lid)):
					var gv := Vector3i(base.x + x, base.y + y, base.z + z)
					var lo := Vector3(x, y, z)
					if Blocks.bottom_of(lid) != Blocks.GLOW_LAMP:
						var up := planet._axis_of(Vector3(gv) + Vector3(0.5, 0.5, 0.5))
						var a := _half_toward(lo, lo + Vector3.ONE, -up)
						var a0: Vector3 = a[0]
						var a1: Vector3 = a[1]
						# thin it on both flat axes so it reads as a post
						var mid: Vector3 = (a0 + a1) * 0.5
						var thin := Vector3(0.16, 0.16, 0.16)
						if absf(up.x) > 0.5: thin.x = (a1.x - a0.x) * 0.5
						elif absf(up.y) > 0.5: thin.y = (a1.y - a0.y) * 0.5
						else: thin.z = (a1.z - a0.z) * 0.5
						_emit_free_box(mid - thin, mid + thin, planet.color_of(lid),
							lid, verts, normals, colors, uvs, uv2s, 1.0)
					else:
						_emit_solid_box_cell(lo, lo + Vector3.ONE, gv, lid,
							planet, snap, verts, normals, colors, uvs, uv2s, cverts)
					lights.append(Vector3(x, y, z) + Vector3(0.5, 0.5, 0.5))
				idx += 1

	# conduit: thin surface-mounted runs. Free boxes, so they are not culled
	# against the wall they hug and carry no collision -- you walk through wiring.
	idx = 0
	for z in CS:
		for y in CS:
			for x in CS:
				var wid := ids[idx]
				if Blocks.bottom_of(wid) == Blocks.WIRE:
					var gv := Vector3i(base.x + x, base.y + y, base.z + z)
					var up := planet._axis_of(Vector3(gv) + Vector3(0.5, 0.5, 0.5))
					var col := planet.color_of(Blocks.WIRE)
					# Reach toward neighbouring conduit only, so arms never
					# poke into the wall the run is stapled to.
					var conn := 0
					for fi2 in 6:
						var nraw := _id_at(planet, snap, gv + _WFACE[fi2])
						if Blocks.bottom_of(nraw) != Blocks.WIRE:
							continue
						conn |= 1 << fi2
						# Turning a corner (floor run meeting a wall run) the two
						# cables lie on different planes. Reach toward the
						# neighbour's mounting face as well, which is the elbow
						# that brings them together instead of leaving a gap.
						conn |= Blocks.wire_faces_of(nraw)
					for bx in shape_boxes(wid, up, conn):
						_emit_free_box(Vector3(x, y, z) + (bx[0] as Vector3),
							Vector3(x, y, z) + (bx[1] as Vector3),
							col, Blocks.WIRE, verts, normals, colors, uvs, uv2s,
							_face_light(snap, gv, Vector3i.ZERO))
				idx += 1

	# eighth-block parts: a workbench leg, a control panel, a machine's guts. Each
	# occupied sub-cell is a half-size box in its own material, and unlike leaves
	# or conduit these DO collide -- you stand on the bench you built.
	var pmap: Dictionary = snap.get(PARTS_KEY, {})
	if not pmap.is_empty():
		idx = 0
		for z in CS:
			for y in CS:
				for x in CS:
					if ids[idx] == Blocks.PARTS:
						var gv := Vector3i(base.x + x, base.y + y, base.z + z)
						var cell = pmap.get(gv)
						if cell != null and (cell as PackedByteArray).size() == Blocks.PART_COUNT:
							var lit := _face_light(snap, gv, Vector3i.ZERO)
							for si in Blocks.PART_COUNT:
								var pid: int = (cell as PackedByteArray)[si]
								if pid == Blocks.AIR:
									continue
								var sx := si % Blocks.PART_DIM
								var sy := (si / Blocks.PART_DIM) % Blocks.PART_DIM
								var sz := si / (Blocks.PART_DIM * Blocks.PART_DIM)
								var plo := Vector3(x + sx * 0.5, y + sy * 0.5, z + sz * 0.5)
								_emit_free_box(plo, plo + Vector3(0.5, 0.5, 0.5),
									_block_color(planet, pid), pid,
									verts, normals, colors, uvs, uv2s, lit, cverts)
					idx += 1

	# ore lumps: decorative geometry on exposed ore faces (see _emit_ore_chunks)
	idx = 0
	for z in CS:
		for y in CS:
			for x in CS:
				if Blocks.is_ore(ids[idx]):
					_emit_ore_chunks(Vector3(x, y, z),
						Vector3i(base.x + x, base.y + y, base.z + z),
						ids[idx], planet, snap, verts, normals, colors, uvs, uv2s)
				idx += 1

	return {"verts": verts, "normals": normals, "colors": colors, "uvs": uvs, "uv2s": uv2s, "lights": lights,
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
		colors: PackedColorArray, uvs: PackedVector2Array, uv2s: PackedVector2Array,
		light: float = 0.0, cverts: PackedVector3Array = PackedVector3Array()) -> void:
	for fi in 6:
		var n: Vector3i = _WFACE[fi]
		var sh := _face_shade(fi / 2, 1 if (fi % 2) == 0 else -1)
		var col := Color(base_col.r * sh, base_col.g * sh, base_col.b * sh, base_col.a)
		var q := _box_face(lo, hi, fi)
		_quad(q[0], q[1], q[2], q[3], Vector3(n), col, verts, normals, colors, uvs, uv2s, bid, sh,
			light, cverts)


## Ore lumps standing proud of an ore block's exposed faces, so a vein reads as
## chunks embedded in rock with real silhouette rather than a pattern painted
## on a flat surface. Only exposed faces grow them -- buried ore is invisible
## anyway, and skipping it keeps the extra geometry proportional to what is
## actually on screen.
static func _emit_ore_chunks(lo: Vector3, gv: Vector3i, id: int, planet: Planet,
		snap: Dictionary, verts: PackedVector3Array, normals: PackedVector3Array,
		colors: PackedColorArray, uvs: PackedVector2Array, uv2s: PackedVector2Array) -> void:
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
				Color(ore_col.r, ore_col.g, ore_col.b, _sky_depth(planet, snap, gv)),
				ORE_CHUNK_ID, verts, normals, colors, uvs, uv2s,
				_face_light(snap, gv, n))


## A stair: the lower half of the cell, plus a step on the upper half.
##
## Facing is which way you CLIMB, so the tall part sits on the facing side. A
## corner keeps only a quarter of that upper step, giving an L you can turn a
## staircase around. Both pieces go through _emit_solid_box_cell, so they
## collide as well as render -- combined with the player's step-up, that is what
## makes a staircase walkable.
static func _emit_stair(lo0: Vector3, gv: Vector3i, raw: int, planet: Planet,
		snap: Dictionary, verts: PackedVector3Array, normals: PackedVector3Array,
		colors: PackedColorArray, uvs: PackedVector2Array, uv2s: PackedVector2Array,
		cverts: PackedVector3Array) -> void:
	var mat := Blocks.base_material_of(Blocks.bottom_of(raw))
	var up := planet._axis_of(Vector3(gv) + Vector3(0.5, 0.5, 0.5))
	for b in shape_boxes(raw, up):
		_emit_solid_box_cell(lo0 + b[0], lo0 + b[1], gv, mat,
			planet, snap, verts, normals, colors, uvs, uv2s, cverts)


## Every solid box a block occupies inside its own cell, as [[lo, hi], ...] in
## 0..1 cell space. ONE definition of each shape, shared by the mesher and the
## placement ghost -- if these diverged, the preview would lie about what you
## are about to build.
## `conn` is a 6-bit mask of _WFACE directions this cell should reach toward --
## only conduit uses it, so a run grows arms toward its neighbours instead of
## sprouting a stub on every cell. The default (all directions) is what a ghost
## preview shows, since a preview has no neighbours yet.
static func shape_boxes(raw: int, up: Vector3, conn: int = 0x3F) -> Array:
	var lo := Vector3.ZERO
	var hi := Vector3.ONE
	var base := Blocks.bottom_of(raw)
	if Blocks.is_stair(base):
		var ax := Vector3(1, 0, 0)
		var bx := Vector3(0, 0, 1)
		if absf(up.x) > 0.5:
			ax = Vector3(0, 1, 0)
		elif absf(up.z) > 0.5:
			bx = Vector3(0, 1, 0)
		var f: Vector3 = [ax, bx, -ax, -bx][Blocks.stair_facing_of(raw)]
		var side: Vector3 = [bx, -ax, -bx, ax][Blocks.stair_facing_of(raw)]
		var step := _half_toward(lo, hi, up)
		step = _half_toward(step[0], step[1], f)
		# A corner keeps only a quarter of the upper step, on one side or the
		# other, so a staircase can turn either way.
		if Blocks.stair_variant_of(raw) == Blocks.STAIR_CORNER:
			step = _half_toward(step[0], step[1], side)
		return [_half_toward(lo, hi, -up), step]
	if base == Blocks.WIRE:
		var faces := Blocks.wire_faces_of(raw)
		if faces == 0:
			# Never placed against anything (hand-given): lie it on the floor.
			for i in 6:
				if Vector3(_WFACE[i]).dot(up) < -0.5:
					faces = 1 << i
					break
		var out: Array = []
		for f in 6:
			if (faces & (1 << f)) == 0:
				continue
			# Reach toward neighbouring cells AND toward the other faces wired in
			# THIS cell -- that second part is what joins a floor run to a wall
			# run inside a single block.
			out.append_array(_wire_boxes(lo, hi, Vector3(_WFACE[f]),
				(conn | faces) & ~(1 << f)))
		return out
	if Blocks.is_stacked_slab(raw):
		return [_half_toward(lo, hi, -up), _half_toward(lo, hi, up)]
	if Blocks.is_slab(base) or base == Blocks.ROOF_SLAB:
		return [_half_toward(lo, hi, -up)]
	return [[lo, hi]]


## One face's worth of conduit: a small junction on the mounting face plus an
## arm toward each direction in `arms`.
static func _wire_boxes(lo: Vector3, hi: Vector3, mount: Vector3, arms: int) -> Array:
	const T := 0.05    # how far it stands off the surface
	const W := 0.10    # how thick the cable is
	const E := 0.004   # held just clear of the wall, so the two never z-fight
	var a := lo
	var b := hi
	if mount.x > 0.5: a.x = hi.x - T - E; b.x = hi.x - E
	elif mount.x < -0.5: b.x = lo.x + T + E; a.x = lo.x + E
	elif mount.y > 0.5: a.y = hi.y - T - E; b.y = hi.y - E
	elif mount.y < -0.5: b.y = lo.y + T + E; a.y = lo.y + E
	elif mount.z > 0.5: a.z = hi.z - T - E; b.z = hi.z - E
	else: b.z = lo.z + T + E; a.z = lo.z + E
	var c0 := a
	var c1 := b
	for axis in 3:
		if absf(mount[axis]) > 0.5:
			continue
		c0[axis] = lo[axis] + 0.5 - W * 0.5
		c1[axis] = lo[axis] + 0.5 + W * 0.5
	var out: Array = [[c0, c1]]
	for fi in 6:
		if (arms & (1 << fi)) == 0:
			continue
		var d := Vector3(_WFACE[fi])
		if absf(d.dot(mount)) > 0.5:
			continue   # into or out of the wall, not along it
		var s0 := c0
		var s1 := c1
		for axis2 in 3:
			if d[axis2] > 0.5:
				s1[axis2] = hi[axis2]
			elif d[axis2] < -0.5:
				s0[axis2] = lo[axis2]
		out.append([s0, s1])
	return out


## The half of a box lying toward `dir`, where `dir` is one of the six unit
## axes. Returned rather than mutated because Vector3 is a value type.
static func _half_toward(lo: Vector3, hi: Vector3, dir: Vector3) -> Array:
	var l := lo
	var h := hi
	var mid := (lo + hi) * 0.5
	if dir.x > 0.5: l.x = mid.x
	elif dir.x < -0.5: h.x = mid.x
	elif dir.y > 0.5: l.y = mid.y
	elif dir.y < -0.5: h.y = mid.y
	elif dir.z > 0.5: l.z = mid.z
	elif dir.z < -0.5: h.z = mid.z
	return [l, h]


static func _emit_water_cell(lo: Vector3, hi: Vector3, gv: Vector3i, planet: Planet,
		snap: Dictionary, wverts: PackedVector3Array, wnormals: PackedVector3Array,
		wcolors: PackedColorArray, wuvs: PackedVector2Array, wuv2s: PackedVector2Array) -> void:
	var base := planet.color_of(Blocks.WATER)
	for fi in 6:
		var n: Vector3i = _WFACE[fi]
		var wnid := _id_at(planet, snap, gv + n)
		if wnid != Blocks.AIR and not Blocks.is_leaf(Blocks.bottom_of(wnid)):
			continue  # only the faces exposed to air are drawn
		var s := _face_shade(fi / 2, 1 if (fi % 2) == 0 else -1)
		var col := Color(base.r * s, base.g * s, base.b * s, _sky_depth(planet, snap, gv))
		var nrm := Vector3(n)
		var q := _box_face(lo, hi, fi)
		_quad(q[0], q[1], q[2], q[3], nrm, col, wverts, wnormals, wcolors, wuvs, wuv2s, Blocks.WATER, s)


static func _emit_solid_box_cell(lo: Vector3, hi: Vector3, gv: Vector3i, id: int, planet: Planet,
		snap: Dictionary, verts: PackedVector3Array, normals: PackedVector3Array,
		colors: PackedColorArray, uvs: PackedVector2Array, uv2s: PackedVector2Array,
		cverts: PackedVector3Array) -> void:
	var base := _block_color(planet, id)
	for fi in 6:
		var n: Vector3i = _WFACE[fi]
		var nid := _id_at(planet, snap, gv + n)
		# A half-height neighbour cannot cover a full face, so it does not hide
		# one -- otherwise a slab beside a block punches a hole in the wall.
		if nid != Blocks.AIR and nid != Blocks.DOOR_OPEN and not Blocks.is_slab(nid) 				and not Blocks.is_stacked_slab(nid) and nid != Blocks.ROOF_SLAB 				and not Blocks.is_stair(Blocks.bottom_of(nid)) 				and not Blocks.is_leaf(Blocks.bottom_of(nid)):
			continue  # only the faces exposed to open space are drawn
		var s := _face_shade(fi / 2, 1 if (fi % 2) == 0 else -1)
		var col := Color(base.r * s, base.g * s, base.b * s, base.a)
		var nrm := Vector3(n)
		var q := _box_face(lo, hi, fi)
		_quad(q[0], q[1], q[2], q[3], nrm, col, verts, normals, colors, uvs, uv2s, id, s,
			_face_light(snap, gv, n), cverts)


static func _box_face(lo: Vector3, hi: Vector3, fi: int) -> Array:
	match fi:
		0: return [Vector3(hi.x, lo.y, lo.z), Vector3(hi.x, hi.y, lo.z), Vector3(hi.x, hi.y, hi.z), Vector3(hi.x, lo.y, hi.z)]  # +X
		1: return [Vector3(lo.x, lo.y, lo.z), Vector3(lo.x, lo.y, hi.z), Vector3(lo.x, hi.y, hi.z), Vector3(lo.x, hi.y, lo.z)]  # -X
		2: return [Vector3(lo.x, hi.y, lo.z), Vector3(lo.x, hi.y, hi.z), Vector3(hi.x, hi.y, hi.z), Vector3(hi.x, hi.y, lo.z)]  # +Y
		3: return [Vector3(lo.x, lo.y, lo.z), Vector3(hi.x, lo.y, lo.z), Vector3(hi.x, lo.y, hi.z), Vector3(lo.x, lo.y, hi.z)]  # -Y
		4: return [Vector3(lo.x, lo.y, hi.z), Vector3(hi.x, lo.y, hi.z), Vector3(hi.x, hi.y, hi.z), Vector3(lo.x, hi.y, hi.z)]  # +Z
		_: return [Vector3(lo.x, lo.y, lo.z), Vector3(lo.x, hi.y, lo.z), Vector3(hi.x, hi.y, lo.z), Vector3(hi.x, lo.y, lo.z)]  # -Z


static func _greedy_pass(planet: Planet, snap: Dictionary, d: int, u: int, v: int,
		dir: int,
		base: Vector3i, ids: PackedInt32Array, strides: Array,
		verts: PackedVector3Array, normals: PackedVector3Array, colors: PackedColorArray,
		wverts: PackedVector3Array, wnormals: PackedVector3Array, wcolors: PackedColorArray,
		uvs: PackedVector2Array, wuvs: PackedVector2Array, uv2s: PackedVector2Array,
		wuv2s: PackedVector2Array, cverts: PackedVector3Array) -> void:
	var sd: int = strides[d]
	var su: int = strides[u]
	var sv: int = strides[v]
	var narr := [0.0, 0.0, 0.0]
	narr[d] = float(dir)
	var normal := Vector3(narr[0], narr[1], narr[2])

	var mask := PackedInt32Array()
	mask.resize(CS * CS)
	# Light is per-VERTEX, so a merged quad can only carry one value. Faces
	# therefore only merge when their light matches as well as their block --
	# without this the whole floor merges into a single quad and a torch's pool
	# of light has nowhere to live. This is why voxel engines key greedy
	# meshing on light level too.
	var lmask := PackedInt32Array()
	lmask.resize(CS * CS)
	# Daylight per face. It has to take part in the merge key, or one quad can
	# span a wall running from the topsoil down into a cave and take a single
	# brightness for the whole thing.
	var smask := PackedInt32Array()
	smask.resize(CS * CS)
	# Hoisted: with no light sources in range _face_light returns 0 immediately,
	# but paying a function call per face to learn that is not free.
	var _lm = snap.get(LM_KEY)
	var has_light: bool = _lm != null and not (_lm as PackedByteArray).is_empty()

	for a in CS:
		for j in CS:
			var row := j * sv
			for k in CS:
				var lin := a * sd + k * su + row
				var oid := ids[lin]
				var val := 0
				if _FULL[oid & Blocks.ID_MASK] == 1:
					var na := a + dir
					var nid: int
					if na >= 0 and na < CS:
						nid = ids[na * sd + k * su + row]
					else:
						nid = _id_at(planet, snap, _global_coord(base, d, u, v, na, k, j))
					var nlow := nid & Blocks.ID_MASK
					if _SEETHRU[nlow] == 1 and not (
							_LEAF[nlow] == 1 and _LEAF[oid & Blocks.ID_MASK] == 1):
						val = oid
				mask[k + j * CS] = val
				smask[k + j * CS] = 15
				if val != 0:
					smask[k + j * CS] = int(round(_sky_depth(planet, snap,
						_global_coord(base, d, u, v, a, k, j)) * 15.0))
				lmask[k + j * CS] = 0
				if val != 0 and has_light:
					lmask[k + j * CS] = int(round(_face_light(snap,
						_global_coord(base, d, u, v, a, k, j),
						Vector3i(int(narr[0]), int(narr[1]), int(narr[2]))) * 15.0))

		var w_coord := a + (1 if dir > 0 else 0)
		_emit_mask(planet, snap, mask, lmask, smask, d, u, v, dir, w_coord, normal,
			verts, normals, colors, wverts, wnormals, wcolors, uvs, wuvs, uv2s, wuv2s,
			cverts, base)


# Opaque blocks use their registry colour, except procedural ores, whose colour is
# defined by the planet (each world's ores look different).
## How much daylight reaches this voxel, from depth below the terrain surface.
## Sampled per QUAD -- greedy meshing means one lookup covers a whole wall.
static func _sky_depth(planet: Planet, snap: Dictionary, gv: Vector3i) -> float:
	var c := Vector3(gv) + Vector3(0.5, 0.5, 0.5)
	var ln := c.length()
	var depth: float = planet.surface_radius(c / maxf(ln, 0.0001)) - planet._norm(c)
	if depth <= SKY_FREE:
		return 1.0
	var f := clampf(1.0 - (depth - SKY_FREE) / SKY_FADE, 0.0, 1.0)
	if f <= 0.0:
		return 0.0
	# Depth below the surface cannot tell a shallow cave from an open hillside:
	# on depth alone a chamber ten blocks under solid rock comes out 80% daylit,
	# which is why caves near the surface still read as lit by the sky. So look
	# UP and see whether anything is actually in the way. Cells deep enough to
	# have no daylight to lose returned above and never pay for this.
	var up := planet._axis_of(c)
	var uq := Vector3i(roundi(up.x), roundi(up.y), roundi(up.z))
	if uq == Vector3i.ZERO:
		return f
	var reach := int(depth) + 2
	for i in range(1, reach):
		if _FULL[_id_at(planet, snap, gv + uq * i) & Blocks.ID_MASK] == 1:
			return 0.0
	return f


static func _block_color(planet: Planet, id: int) -> Color:
	# Ore blocks are meshed as STONE. The ore itself is drawn by the shader as
	# chunks embedded in that stone (colour supplied per planet via uniforms),
	# rather than the whole block being one flat ore colour.
	if Blocks.is_ore(id):
		return planet.color_of(planet.pal_rock)
	# Per-planet, not per-registry: the block id stays global so recipes and
	# inventories are unchanged, while what you see belongs to this world.
	return planet.color_of(id)


static func _emit_mask(planet: Planet, snap: Dictionary, mask: PackedInt32Array,
		lmask: PackedInt32Array, smask: PackedInt32Array, d: int, u: int, v: int, dir: int, w_coord: int,
		normal: Vector3,
		verts: PackedVector3Array, normals: PackedVector3Array, colors: PackedColorArray,
		wverts: PackedVector3Array, wnormals: PackedVector3Array, wcolors: PackedColorArray,
		uvs: PackedVector2Array, wuvs: PackedVector2Array, uv2s: PackedVector2Array,
		wuv2s: PackedVector2Array, cverts: PackedVector3Array,
		base: Vector3i) -> void:
	for j in CS:
		var k := 0
		while k < CS:
			var val := mask[k + j * CS]
			if val == 0:
				k += 1
				continue
			var lv := lmask[k + j * CS]
			var sv := smask[k + j * CS]
			var wdt := 1
			while k + wdt < CS and mask[k + wdt + j * CS] == val 					and lmask[k + wdt + j * CS] == lv and smask[k + wdt + j * CS] == sv:
				wdt += 1
			var hgt := 1
			var stop := false
			while j + hgt < CS and not stop:
				for x in wdt:
					if mask[k + x + (j + hgt) * CS] != val 							or lmask[k + x + (j + hgt) * CS] != lv 							or smask[k + x + (j + hgt) * CS] != sv:
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
			var bcol := _block_color(planet, val)
			var col := Color(bcol.r * s, bcol.g * s, bcol.b * s, bcol.a)  # keep alpha (water)
			if val != Blocks.WATER:
				col.a = float(sv) / 15.0   # opaque terrain: alpha carries daylight
			var p00 := _corner(d, u, v, w_coord, k, j)
			var p10 := _corner(d, u, v, w_coord, k + wdt, j)
			var p11 := _corner(d, u, v, w_coord, k + wdt, j + hgt)
			var p01 := _corner(d, u, v, w_coord, k, j + hgt)
			if val == Blocks.WATER:
				if dir > 0:
					_quad(p00, p10, p11, p01, normal, col, wverts, wnormals, wcolors, wuvs, wuv2s, val, s)
				else:
					_quad(p00, p01, p11, p10, normal, col, wverts, wnormals, wcolors, wuvs, wuv2s, val, s)
			else:
				if dir > 0:
					_quad(p00, p10, p11, p01, normal, col, verts, normals, colors, uvs, uv2s, val, s,
						float(lv) / 15.0, cverts)
				else:
					_quad(p00, p01, p11, p10, normal, col, verts, normals, colors, uvs, uv2s, val, s,
						float(lv) / 15.0, cverts)
			k += wdt


static func _quad(a: Vector3, b: Vector3, c: Vector3, e: Vector3, normal: Vector3, col: Color,
		verts: PackedVector3Array, normals: PackedVector3Array, colors: PackedColorArray,
		uvs: PackedVector2Array, uv2s: PackedVector2Array, bid: int, shade: float,
		face_light: float = 0.0,
		cverts: PackedVector3Array = PackedVector3Array()) -> void:
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
		# Packed orientation bits are stripped here: UV.x is only ever the plain
		# block id the shader keys its material off.
		uvs.append(Vector2(float(Blocks.bottom_of(bid)) / ID_SCALE, shade))
		# UV2.x carries a log's trunk axis, so the shader knows which two faces
		# are cut ends instead of guessing from the planet's up (only right for
		# an upright trunk). 3 = "not a log".
		var _la := Blocks.log_axis_of(bid) if Blocks.is_wood(Blocks.bottom_of(bid)) else -1
		# UV2.y carries the baked block light for this face (see
		# _compute_block_light). Hard-coding 0.0 here silently discarded a value
		# that was computed, flood-filled and threaded all the way down.
		uv2s.append(Vector2(float(_la) if _la >= 0 else 3.0, face_light))


## Per-face shading baked into the vertex colour, by face orientation.
##
## This is deliberately SUBTLE. It used to carry the whole sense of direction
## (up 1.0 down 0.5), which looked right only while the sun never moved -- baked
## at mesh time, it cannot follow a day/night cycle, so at midnight every
## surface still read as lit from overhead. It is now a narrow ambient-occlusion
## style bias that gives faces definition, and the real DirectionalLight3D
## supplies the actual direction. Widening this range again would re-break
## night lighting.
static func _face_shade(d: int, dir: int) -> float:
	if d == 1:  # Y axis
		return 1.0 if dir > 0 else 0.86
	if d == 0:  # X axis
		return 0.94 if dir > 0 else 0.92
	return 0.96 if dir > 0 else 0.90  # Z axis


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
