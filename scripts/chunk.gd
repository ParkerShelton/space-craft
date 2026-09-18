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


static var _grass_material: ShaderMaterial

## Ground cover's own material. Separate from the terrain's on purpose: the blade
## cutout needs a discard the terrain shader has no business carrying, and a
## separate surface cannot corrupt the terrain mesh.
static func _get_grass_material() -> ShaderMaterial:
	if _grass_material == null:
		_grass_material = ShaderMaterial.new()
		_grass_material.shader = load("res://shaders/grass_blade.gdshader")
	return _grass_material


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
	var gverts: PackedVector3Array = data.get("gverts", PackedVector3Array())
	if not gverts.is_empty():
		var garr := []
		garr.resize(Mesh.ARRAY_MAX)
		garr[Mesh.ARRAY_VERTEX] = gverts
		garr[Mesh.ARRAY_NORMAL] = data["gnormals"]
		garr[Mesh.ARRAY_COLOR] = data["gcolors"]
		garr[Mesh.ARRAY_TEX_UV] = data["guvs"]
		m.add_surface_from_arrays(Mesh.PRIMITIVE_TRIANGLES, garr)
		m.surface_set_material(m.get_surface_count() - 1, _get_grass_material())
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
			or id == Blocks.DOOR or id == Blocks.DOOR_OPEN or id == Blocks.ROOF_SLAB
			or Blocks.is_slab(id) or Blocks.is_stair(id) or Blocks.is_light(id)
			or Blocks.is_wire(id) or id == Blocks.PARTS
			or id == Blocks.YOUNG_TREE
			or Blocks.is_plant(id))
		_FULL[id] = 1 if full else 0
		# Leaves are meshed AND see-through: they are drawn with cutout holes, so
		# they must not hide the block behind them.
		_SEETHRU[id] = 1 if (not full or Blocks.is_leaf(id)) else 0
		_LEAF[id] = 1 if Blocks.is_leaf(id) else 0


static func _id_at(planet: Planet, snap: Dictionary, v: Vector3i) -> int:
	if snap.has(v):
		return snap[v]
	return planet.generation_sample(v.x, v.y, v.z, snap.get(TCACHE_KEY))


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
## Campfire cells reach the mesher through the snapshot under this key (see
## Planet._edits_snapshot). A fire is not a block, so it cannot be found by
## walking block ids the way a torch can.
const FIRE_KEY := "fires"
## Planted cells near this chunk: voxel -> {key, stage, tree}. A crop's height
## comes from how far along it is, and that is not in its block id.
const CROP_KEY := "crops"
## Per-build memo of which tree cells hold a tree (see Planet.generation_sample).
## Lives in the snapshot because the snapshot is already private to one worker
## task, which is exactly the lifetime and the isolation this needs.
const TCACHE_KEY := "tcache"
## How far a campfire throws light. A shade under a torch: it is a hearth, not
## a lamp on a pole.
const FIRE_LIGHT := 10

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
	# Campfires seed the flood too. They are not blocks, so they arrive as their
	# own list rather than being found among the edited cells above.
	for fv in snap.get(FIRE_KEY, []):
		var fp: Vector3i = (fv as Vector3i) - origin
		if fp.x < 0 or fp.y < 0 or fp.z < 0 				or fp.x >= LIGHT_DIM or fp.y >= LIGHT_DIM or fp.z >= LIGHT_DIM:
			continue
		seeds.append([fp.x, fp.y, fp.z, FIRE_LIGHT])
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


# --- daylight ---------------------------------------------------------------
#
# Skylight is flood-filled from the open sky, the same way torch light is
# flood-filled from a torch, and for the same reason: it is the only model that
# is smooth AND knows about roofs.
#
# What came before was a function of how deep a cell sits below the terrain
# surface. Depth alone cannot tell a cave with ten blocks of rock over it from
# open ground ten blocks down a hillside, so a roofed cave was lit like a field.
# Every attempt to fix that by asking "can this cell see the sky" put a
# VISIBILITY test in the middle of a smooth field: two cells side by side in one
# wall answer differently, greedy meshing hands each answer to a whole flat
# quad, and the wall comes out in patches.
#
# A flood fill has neither problem. Light starts at the sky, spreads only
# through what it can pass through, and loses a level per block -- so a roof
# stops it, and neighbouring cells can never differ by more than one level. The
# patchwork and the daylit cave are the same bug, and this is the one fix.
const SKY_PAD := 15
const SKY_DIM := CS + SKY_PAD * 2
const SKY_MAX := 15
## Where the finished map and its corner ride along in the snapshot.
const SKY_KEY := "__skylight"
const SKY_ORG := "__skyorigin"
## How far down a column is followed from the surface before giving up. Only a
## shaft ever gets far: ordinary ground stops it on the first or second block,
## which is what keeps this affordable for a chunk that is a long way down.
const SKY_COLUMN_STEPS := 224
## Below this depth a chunk that nobody has touched is simply dark, and the
## whole pass is skipped. Daylight only gets that far down a straight shaft, and
## a straight shaft that deep is something a player DUG -- which puts edits in
## the snapshot and takes the full path below. Natural caves reach further than
## this, but never with a clear column above them: their light arrives along
## winding tunnels, and fifteen levels of falloff has long since spent it.
const SKY_DEEP := 24.0


static func _sky_index(x: int, y: int, z: int) -> int:
	return x + y * SKY_DIM + z * SKY_DIM * SKY_DIM


## Does daylight get through this cell? Leaves and water do not stop it -- a
## canopy dims what is under it rather than putting it in a cave, and treating
## foliage as opaque here used to seal off most of the ground on a wooded planet.
static func _sky_open(planet: Planet, snap: Dictionary, v: Vector3i) -> bool:
	var low := _id_at(planet, snap, v) & Blocks.ID_MASK
	return _FULL[low] == 0 or _LEAF[low] == 1


## Blocks below the terrain surface, at this exact cell.
static func _depth_of(planet: Planet, gv: Vector3i) -> float:
	var c := Vector3(gv) + Vector3(0.5, 0.5, 0.5)
	return planet.surface_radius(c / maxf(c.length(), 0.0001)) - planet._norm(c)


## Daylight for the chunk at `base` and the padding around it, 0..15 per cell.
static func _compute_skylight(planet: Planet, snap: Dictionary, base: Vector3i) -> PackedByteArray:
	var origin := base - Vector3i(SKY_PAD, SKY_PAD, SKY_PAD)
	var sky := PackedByteArray()
	sky.resize(SKY_DIM * SKY_DIM * SKY_DIM)

	# Whether anyone has built anything around here at all. Almost never, and
	# knowing it up front is what lets a buried chunk skip out below, and what
	# turns the per-step "did somebody put a block in this patch of open sky"
	# question into a boolean instead of a dictionary lookup for every one of the
	# ten-odd blocks of air a surface column crosses.
	var edited := false
	for k in snap:
		if k is Vector3i:
			edited = true
			break
	# Deep, untouched rock is dark, and finding that out the long way costs a
	# terrain sample for every column in the region. Half the chunks a player
	# streams in are this, so it is worth the one probe: the chunk's own centre,
	# less its half-diagonal, is the shallowest any of its cells can be.
	var mid_depth := _depth_of(planet, base + Vector3i(CS / 2, CS / 2, CS / 2))
	if not edited and mid_depth - float(CS) * 0.87 > SKY_DEEP:
		return sky

	# Which way is up for this whole region. On a cube planet that is the face
	# normal, not the direction away from the centre -- the two disagree
	# everywhere except the middle of a face.
	var centre := Vector3(base) + Vector3.ONE * (float(CS) * 0.5)
	var up: Vector3 = planet._axis_of(centre) if planet.shape_cube else centre.normalized()
	var uq := Vector3i(roundi(up.x), roundi(up.y), roundi(up.z))
	if uq == Vector3i.ZERO:
		for i in sky.size():
			sky[i] = SKY_MAX
		return sky

	var ax := 0 if uq.x != 0 else (1 if uq.y != 0 else 2)
	var sgn := uq[ax]
	var la := (ax + 1) % 3
	var lb := (ax + 2) % 3
	var strides := [1, SKY_DIM, SKY_DIM * SKY_DIM]
	var s_ax: int = strides[ax]
	var s_la: int = strides[la]
	var s_lb: int = strides[lb]
	# d counts DOWNWARD from the top of the region, so the two cube-face
	# directions can share one loop instead of being mirrored by hand.
	var t_top := SKY_DIM - 1 if sgn > 0 else 0
	var down := -sgn

	# --- pass one: every cell with nothing but sky above it ------------------
	# Done per COLUMN rather than per cell, and it stops at the first solid
	# block, so a chunk hundreds of blocks down still costs about one terrain
	# sample per column: the ground right under the surface stops it at once.
	var lip := PackedInt32Array()
	lip.resize(SKY_DIM * SKY_DIM)
	for i in lip.size():
		lip[i] = -1
	for a in SKY_DIM:
		for b in SKY_DIM:
			var gv := origin
			gv[ax] += t_top
			gv[la] += a
			gv[lb] += b
			# Start at the surface, which for a buried region is above the top of
			# it. Depth falls by one per block climbed, so where it reaches zero is
			# one subtraction rather than a walk.
			var depth := _depth_of(planet, gv)
			var d := 0
			if depth > 0.0:
				var climb := int(ceil(depth))
				if climb > SKY_COLUMN_STEPS:
					continue      # far too deep for daylight to reach by any route
				gv += uq * climb
				d = -climb
			var deepest := -1
			var steps := 0
			# `depth` is carried along rather than recomputed: one step down is one
			# block deeper, and the terrain sample it saves is the expensive part.
			var dep := depth
			# Everything above the terrain surface is air by definition, so the run
			# from the top of the region down to the surface is written straight in
			# rather than walked a block at a time. At the surface that is a dozen
			# cells per column and the walk around them was the single most
			# expensive thing in the build.
			if dep < -1.0 and not edited:
				var air := mini(int(floor(-dep)), SKY_DIM - maxi(d, 0))
				if air > 0:
					var dd := maxi(d, 0)
					var stop := dd + air
					while dd < stop:
						sky[(t_top + dd * down) * s_ax + a * s_la + b * s_lb] = SKY_MAX
						dd += 1
					deepest = stop - 1
					gv -= uq * (stop - maxi(d, 0))
					dep += float(stop - maxi(d, 0))
					d = stop
			while steps < SKY_COLUMN_STEPS:
				# Above the terrain surface there is nothing to ask the generator
				# about -- it is air by definition. Only a cell somebody has BUILT
				# up there can prove otherwise, and the snapshot already knows which
				# those are. Skipping the sample here is most of what this costs at
				# the surface, where a column crosses twelve blocks of open sky
				# before it reaches the ground.
				if dep > -0.5 or (edited and snap.has(gv)):
					if not _sky_open(planet, snap, gv):
						break
				if d >= 0:
					if d >= SKY_DIM:
						break
					sky[(t_top + d * down) * s_ax + a * s_la + b * s_lb] = SKY_MAX
					deepest = d
				gv -= uq
				dep += 1.0
				d += 1
				steps += 1
			lip[a + b * SKY_DIM] = deepest

	# --- pass two: spread it sideways ---------------------------------------
	# Started at the DARK cells beside an open column rather than at the open
	# cells themselves: a cave mouth, an overhang, the shaded side of a boulder.
	# Seeding the open cells instead meant asking each of them about all six of
	# its neighbours, and on rolling ground almost every one of those neighbours
	# is either open sky already or solid rock -- thousands of terrain samples to
	# discover there was nowhere for the light to go.
	# Seeded only where daylight actually has somewhere to go: the bottom of each
	# open column, and the cells of a column that reach past a neighbour's. Those
	# are the cave mouths and the overhangs. Seeding every open cell instead
	# would push tens of thousands of cells that are already fully lit and
	# surrounded by cells that are already fully lit.
	var frontier: Array = []
	for a in SKY_DIM:
		for b in SKY_DIM:
			var lc: int = lip[a + b * SKY_DIM]
			if lc < 0:
				continue
			for e in 4:
				var na := a + (1 if e == 0 else (-1 if e == 1 else 0))
				var nb := b + (1 if e == 2 else (-1 if e == 3 else 0))
				if na < 0 or nb < 0 or na >= SKY_DIM or nb >= SKY_DIM:
					continue
				var ln: int = lip[na + nb * SKY_DIM]
				if ln >= lc:
					continue
				for dd in range(maxi(ln + 1, 0), lc + 1):
					var cell := _sky_cell(na, nb, dd, t_top, down, ax, la, lb)
					var ci := _sky_index(cell.x, cell.y, cell.z)
					if sky[ci] >= SKY_MAX - 1:
						continue
					if not _sky_open(planet, snap, origin + cell):
						continue
					sky[ci] = SKY_MAX - 1
					frontier.append(cell)

	var nb6 := [Vector3i(1, 0, 0), Vector3i(-1, 0, 0), Vector3i(0, 1, 0),
		Vector3i(0, -1, 0), Vector3i(0, 0, 1), Vector3i(0, 0, -1)]
	while not frontier.is_empty():
		var nxt: Array = []
		for c in frontier:
			var here: int = sky[_sky_index(c.x, c.y, c.z)]
			if here <= 1:
				continue
			for dv in nb6:
				var n: Vector3i = c + dv
				if n.x < 0 or n.y < 0 or n.z < 0 						or n.x >= SKY_DIM or n.y >= SKY_DIM or n.z >= SKY_DIM:
					continue
				var ni := _sky_index(n.x, n.y, n.z)
				if sky[ni] >= here - 1:
					continue
				if not _sky_open(planet, snap, origin + n):
					continue
				sky[ni] = here - 1
				nxt.append(n)
		frontier = nxt
	return sky


## One cell of a column, as local coordinates in the padded region.
static func _sky_cell(a: int, b: int, d: int, t_top: int, down: int,
		ax: int, la: int, lb: int) -> Vector3i:
	var v := Vector3i.ZERO
	v[ax] = t_top + d * down
	v[la] = a
	v[lb] = b
	return v


static func build_mesh_data(planet: Planet, cc: Vector3i, snap: Dictionary, wsnap: Dictionary = {}) -> Dictionary:
	var base := cc * CS
	snap[LB_KEY] = base
	if not snap.has(TCACHE_KEY):
		snap[TCACHE_KEY] = {}
	snap[LM_KEY] = _compute_block_light(planet, snap, base)
	snap[SKY_ORG] = base - Vector3i(SKY_PAD, SKY_PAD, SKY_PAD)
	snap[SKY_KEY] = _compute_skylight(planet, snap, base)
	var ids := PackedInt32Array()
	ids.resize(CS * CS * CS)
	# 1-based region per cell, 0 for "not tinted". A byte each: this is a
	# throwaway 32k that lives as long as one chunk build.
	var bslot := PackedByteArray()
	bslot.resize(CS * CS * CS)
	var any_solid := false
	var i := 0
	for z in CS:
		for y in CS:
			for x in CS:
				var gvi := Vector3i(base.x + x, base.y + y, base.z + z)
				var id := _id_at(planet, snap, gvi)
				ids[i] = id
				# Which region colours this cell, if any. Asked only for the two
				# materials a region actually tints -- its topsoil and its
				# subsoil -- because it is a noise lookup and most of a chunk is
				# rock that would never use the answer.
				if planet.biome_tints(id):
					bslot[i] = planet.biome_slot_at(gvi)
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
	# Ground cover gets its OWN surface. It was previously appended into the
	# terrain arrays, which corrupted that surface and stopped whole chunks
	# rendering -- you could see straight through the world.
	var gverts := PackedVector3Array()
	var gnormals := PackedVector3Array()
	var gcolors := PackedColorArray()
	var guvs := PackedVector2Array()
	# Water in this chunk with somewhere to go: a cell with air against it.
	#
	# Collected HERE because this is the one pass that already walks every cell
	# of the chunk and asks each water cell what is beside it. The simulation
	# only ever runs where something wakes it, and until now the only thing that
	# did was an edit -- so a sea sitting over a cave mouth the world generated
	# hung there, unsupported, until you happened to break a block near it.
	var wetfall := PackedVector3Array()
	if not any_solid:
		return {"verts": verts, "normals": normals, "colors": colors, "uvs": uvs, "uv2s": uv2s, "lights": PackedVector3Array(),
			"cverts": cverts, "wverts": wverts, "wnormals": wnormals, "wcolors": wcolors,
			"gverts": gverts, "gnormals": gnormals, "gcolors": gcolors, "guvs": guvs,
			"wetfall": wetfall}

	# opaque terrain via greedy meshing (water is skipped here, handled below)
	var strides := [1, CS, CS * CS]
	for d in 3:
		var u := (d + 1) % 3
		var v := (d + 2) % 3
		for dir in [1, -1]:
			_greedy_pass(planet, snap, d, u, v, dir, base, ids, bslot, strides,
				verts, normals, colors, wverts, wnormals, wcolors, uvs, wuvs, uv2s, wuv2s,
				cverts)

	# water: one box per cell, its height set by the water level (shallow water
	# renders lower). Fill is along the cell's outward axis (radial-snapped).
	var idx := 0
	for z in CS:
		for y in CS:
			for x in CS:
				if ids[idx] == Blocks.WATER:
					var gv := Vector3i(base.x + x, base.y + y, base.z + z)
					var up := planet._axis_of(Vector3(gv) + Vector3(0.5, 0.5, 0.5))
					_emit_water_cell(Vector3(x, y, z), gv, up, _water_h(wsnap, gv),
						planet, snap, wsnap, wverts, wnormals, wcolors, wuvs, wuv2s,
						wetfall)
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
				if Blocks.is_stair(Blocks.bottom_of(hid)) or Blocks.is_door(hid):
					_emit_shaped(Vector3(x, y, z),
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
						var tb := torch_box(up)
						var mid: Vector3 = lo + (tb[0] as Vector3)
						var thin: Vector3 = lo + (tb[1] as Vector3)
						_emit_free_box(mid, thin, planet.color_of(lid),
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

	# tall grass: two quads crossed in an X per cell, the way every block game
	# draws ground cover. Its own arrays, its own surface, no collision.
	idx = 0
	for z in CS:
		for y in CS:
			for x in CS:
				if Blocks.bottom_of(ids[idx]) == Blocks.TALL_GRASS:
					var ggv := Vector3i(base.x + x, base.y + y, base.z + z)
					_emit_grass(Vector3(x, y, z),
						planet._axis_of(Vector3(ggv) + Vector3(0.5, 0.5, 0.5)),
						# The colour of the ground it stands on, not a fixed green: every
						# planet tints its own soil, and grass that ignored that sat on
						# the surface looking like it belonged to a different world.
						planet.color_of(planet.pal_top), ggv,
						_sky_depth(snap, ggv), 1.0,
						gverts, gnormals, gcolors, guvs)
				idx += 1

	# planted cells: a crop is grass whose height is how far along it is, and a
	# young tree is a skinny post -- thinner than a log on purpose, so a sapling
	# coming up never reads as something you could have built.
	var planted: Dictionary = snap.get(CROP_KEY, {})
	for pv in planted:
		var pl: Vector3i = (pv as Vector3i) - base
		if pl.x < 0 or pl.y < 0 or pl.z < 0 or pl.x >= CS or pl.y >= CS or pl.z >= CS:
			continue
		var info: Dictionary = planted[pv]
		var gpv: Vector3i = pv
		var pup: Vector3 = planet._axis_of(Vector3(gpv) + Vector3(0.5, 0.5, 0.5))
		if bool(info.get("tree", false)):
			var uq2 := Vector3(roundi(pup.x), roundi(pup.y), roundi(pup.z))
			var flo := Vector3(pl)
			var lo2: Vector3 = flo + Vector3(0.42, 0.0, 0.42)
			var hi2: Vector3 = flo + Vector3(0.58, 0.9, 0.58)
			if absf(uq2.x) > 0.5:
				lo2 = flo + Vector3(0.0, 0.42, 0.42)
				hi2 = flo + Vector3(0.9, 0.58, 0.58)
			elif absf(uq2.z) > 0.5:
				lo2 = flo + Vector3(0.42, 0.42, 0.0)
				hi2 = flo + Vector3(0.58, 0.58, 0.9)
			_emit_free_box(lo2, hi2, planet.color_of(planet.flora_wood),
				Blocks.YOUNG_TREE, verts, normals, colors, uvs, uv2s,
				_face_light(snap, gpv, Vector3i.ZERO))
		else:
			var stage := int(info.get("stage", 0))
			var total := int(Blocks.crop_growth(str(info.get("key", "")))["stages"])
			var ripe := stage >= total - 1
			_emit_grass(Vector3(pl), pup, Blocks.crop_color(ripe), gpv,
				_sky_depth(snap, gpv), Blocks.crop_height(stage, total),
				gverts, gnormals, gcolors, guvs)

	# campfire flames. Emissive geometry standing above the fuel, because four
	# wood eighths on the ground do not read as a fire on their own -- and unlike
	# the parts themselves these carry no collision, so you walk through the flame
	# rather than being stopped by it.
	for fv in snap.get(FIRE_KEY, []):
		var fl: Vector3i = (fv as Vector3i) - base
		if fl.x < 0 or fl.y < 0 or fl.z < 0 or fl.x >= CS or fl.y >= CS or fl.z >= CS:
			continue
		var flo := Vector3(fl)
		var fcol := planet.color_of(Blocks.CAMPFIRE)
		for fb in [[Vector3(0.28, 0.48, 0.28), Vector3(0.72, 0.98, 0.72)],
				[Vector3(0.16, 0.48, 0.40), Vector3(0.40, 0.80, 0.64)],
				[Vector3(0.58, 0.48, 0.22), Vector3(0.80, 0.74, 0.46)],
				[Vector3(0.38, 0.92, 0.38), Vector3(0.62, 1.22, 0.62)]]:
			_emit_free_box(flo + (fb[0] as Vector3), flo + (fb[1] as Vector3),
				fcol, Blocks.CAMPFIRE, verts, normals, colors, uvs, uv2s, 1.0)

	# eighth-block parts: a workbench leg, a control panel, a machine's guts. Each
	# occupied sub-cell is a half-size box in its own material, and unlike leaves
	# or conduit these DO collide -- you stand on the bench you built.
	var pmap: Dictionary = snap.get(PARTS_KEY, {})
	if not pmap.is_empty():
		# Driven by the parts map rather than by a sweep of all 4096 voxels. A
		# build is a handful of cells, and the sweep cost the same whether the
		# chunk held one eighth-block or a thousand.
		for gv in pmap:
			var lx: int = int(gv.x) - base.x
			var ly: int = int(gv.y) - base.y
			var lz: int = int(gv.z) - base.z
			if lx < 0 or ly < 0 or lz < 0 or lx >= CS or ly >= CS or lz >= CS:
				continue
			if ids[lx + ly * CS + lz * CS * CS] != Blocks.PARTS:
				continue
			var cell = pmap[gv]
			if (cell as PackedByteArray).size() != Blocks.PART_COUNT:
				continue
			var lit := _face_light(snap, gv, Vector3i.ZERO)
			for si in Blocks.PART_COUNT:
				var pid: int = (cell as PackedByteArray)[si]
				if pid == Blocks.AIR:
					continue
				var sx := si % Blocks.PART_DIM
				var sy := (si / Blocks.PART_DIM) % Blocks.PART_DIM
				var sz := si / (Blocks.PART_DIM * Blocks.PART_DIM)
				# Every face pressed against another filled eighth is dropped.
				# These are not just invisible, they are doubled: two boxes each
				# drawing the surface between them, in the mesh AND in the
				# collision shape you walk on.
				var skip := 0
				for fi in 6:
					var nn: Vector3i = _WFACE[fi]
					if _part_solid(pmap, gv, sx + nn.x, sy + nn.y, sz + nn.z):
						skip |= 1 << fi
				if skip == 63:
					continue   # buried on all six sides: nothing of it is visible
				var plo := Vector3(lx + sx * 0.5, ly + sy * 0.5, lz + sz * 0.5)
				_emit_free_box(plo, plo + Vector3(0.5, 0.5, 0.5),
					_block_color(planet, pid), pid,
					verts, normals, colors, uvs, uv2s, lit, cverts, skip)

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
		"cverts": cverts, "wverts": wverts, "wnormals": wnormals, "wcolors": wcolors,
		"gverts": gverts, "gnormals": gnormals, "gcolors": gcolors, "guvs": guvs,
		"wetfall": wetfall}


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
## `skip` is a bitmask of faces to leave out, one bit per _WFACE direction.
## Free boxes that touch each other -- eighth-block parts, mostly -- would
## otherwise each draw the face they are pressed against, twice over and facing
## each other, where neither can ever be seen.
static func _emit_free_box(lo: Vector3, hi: Vector3, base_col: Color, bid: int,
		verts: PackedVector3Array, normals: PackedVector3Array,
		colors: PackedColorArray, uvs: PackedVector2Array, uv2s: PackedVector2Array,
		light: float = 0.0, cverts: PackedVector3Array = PackedVector3Array(),
		skip: int = 0) -> void:
	for fi in 6:
		if (skip & (1 << fi)) != 0:
			continue
		var n: Vector3i = _WFACE[fi]
		var sh := _face_shade(fi / 2, 1 if (fi % 2) == 0 else -1)
		var col := Color(base_col.r * sh, base_col.g * sh, base_col.b * sh, base_col.a)
		var q := _box_face(lo, hi, fi)
		_quad(q[0], q[1], q[2], q[3], Vector3(n), col, verts, normals, colors, uvs, uv2s, bid, sh,
			light, cverts)


## Is the sub-cell at these coordinates filled? Coordinates outside 0..PART_DIM-1
## wrap into the neighbouring VOXEL's parts cell, so two eighth-blocks touching
## across a block boundary hide each other's faces just as they would inside one
## cell -- which is most of the boundaries in a build of any size.
static func _part_solid(pmap: Dictionary, gv: Vector3i, nx: int, ny: int, nz: int) -> bool:
	var d := Vector3i.ZERO
	var m := Blocks.PART_DIM
	if nx < 0:
		d.x = -1
		nx = m - 1
	elif nx >= m:
		d.x = 1
		nx = 0
	if ny < 0:
		d.y = -1
		ny = m - 1
	elif ny >= m:
		d.y = 1
		ny = 0
	if nz < 0:
		d.z = -1
		nz = m - 1
	elif nz >= m:
		d.z = 1
		nz = 0
	var cell = pmap.get(gv + d)
	if cell == null or (cell as PackedByteArray).size() != Blocks.PART_COUNT:
		return false
	# The mesher's own occlusion table rather than "not air", so an eighth of
	# something see-through does not hide its neighbour's face the way a solid
	# one does -- the same rule whole blocks already follow.
	var pid: int = (cell as PackedByteArray)[nx + ny * m + nz * m * m]
	return pid != Blocks.AIR and _SEETHRU[pid & Blocks.ID_MASK] == 0


## Ore lumps standing proud of an ore block's exposed faces, so a vein reads as
## chunks embedded in rock with real silhouette rather than a pattern painted
## on a flat surface. Only exposed faces grow them -- buried ore is invisible
## anyway, and skipping it keeps the extra geometry proportional to what is
## actually on screen.
## Two vertical quads crossed through the middle of a cell. Both are drawn from
## either side (the material never culls), so a tuft reads from every angle.
static func _emit_grass(lo: Vector3, up: Vector3, col: Color, gv: Vector3i,
		sky: float, scale: float,
		gverts: PackedVector3Array, gnormals: PackedVector3Array,
		gcolors: PackedColorArray, guvs: PackedVector2Array) -> void:
	var uq := Vector3(roundi(up.x), roundi(up.y), roundi(up.z))
	if uq == Vector3.ZERO:
		return
	var t1 := Vector3(uq.y, uq.z, uq.x)
	var t2 := Vector3(uq.z, uq.x, uq.y)
	# sitting on the floor of the cell, nudged off-centre per cell so a field is
	# not a grid of identical crosses
	var c := lo + Vector3(0.5, 0.5, 0.5) - uq * 0.5
	var h := (0.62 + _hash3(gv, 5) * 0.36) * scale
	c += t1 * ((_hash3(gv, 6) - 0.5) * 0.34) + t2 * ((_hash3(gv, 7) - 0.5) * 0.34)
	# UV.x is the position ACROSS the quad, UV.y the height up the blade. Both are
	# per-vertex; the shader cuts the blades out of the quad using them.
	var hs := [0.0, 0.0, 1.0, 0.0, 1.0, 1.0]
	var xs := [0.0, 1.0, 1.0, 0.0, 1.0, 0.0]
	for d in [t1 + t2, t1 - t2]:
		var a: Vector3 = d.normalized() * 0.5
		var p0: Vector3 = c - a
		var p1: Vector3 = c + a
		var p2: Vector3 = p1 + uq * h
		var p3: Vector3 = p0 + uq * h
		var nrm: Vector3 = a.cross(uq).normalized()
		var quad := [p0, p1, p2, p0, p2, p3]
		for k in 6:
			gverts.append(quad[k])
			gnormals.append(nrm)
			# Alpha carries the skylight, the same channel and the same meaning the
			# terrain uses, so grass lights identically to the ground under it.
			gcolors.append(Color(col.r, col.g, col.b, sky))
			guvs.append(Vector2(xs[k], hs[k]))


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
				Color(ore_col.r, ore_col.g, ore_col.b, _sky_depth(snap, gv + n)),
				ORE_CHUNK_ID, verts, normals, colors, uvs, uv2s,
				_face_light(snap, gv, n))


## A stair: the lower half of the cell, plus a step on the upper half.
##
## Facing is which way you CLIMB, so the tall part sits on the facing side. A
## corner keeps only a quarter of that upper step, giving an L you can turn a
## staircase around. Both pieces go through _emit_solid_box_cell, so they
## collide as well as render -- combined with the player's step-up, that is what
## makes a staircase walkable.
## Every box a block occupies, drawn. Stairs and doors both: neither is a cube,
## and both are described once in shape_boxes so the mesh, the collision and the
## placement preview cannot disagree about where they are.
static func _emit_shaped(lo0: Vector3, gv: Vector3i, raw: int, planet: Planet,
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
	if base == Blocks.DOOR or base == Blocks.DOOR_OPEN:
		# A door is a PANEL on one edge of its cell, not a cube filling it.
		#
		# Closed, it lies across the doorway with its face toward whoever put it
		# there. Open, the same panel has swung a quarter turn onto the edge it
		# is hinged to -- which is the whole of what makes a door read as a door
		# rather than as a block that stopped being solid.
		const DOOR_THICK := 3.0 / 16.0
		var dax := Vector3(1, 0, 0)
		var dbx := Vector3(0, 0, 1)
		if absf(up.x) > 0.5:
			dax = Vector3(0, 1, 0)
		elif absf(up.z) > 0.5:
			dbx = Vector3(0, 1, 0)
		var dirs := [dax, dbx, -dax, -dbx]
		var df: Vector3 = dirs[Blocks.door_facing_of(raw)]
		# The hinge edge: one quarter turn from the face, either way round.
		var dh: Vector3 = dirs[(Blocks.door_facing_of(raw) + 1) % 4]
		if Blocks.door_hinge_of(raw) == 1:
			dh = -dh
		# SHUT, it sits down the middle of its cell rather than flush against one
		# face -- a door hugging one side of its own doorway leaves a gap down
		# the other, and a wall with a door in it should read straight.
		#
		# OPEN, it is against the edge it hinges on, which is where a door that
		# has swung out of the way actually is. That is also the only thing the
		# hinge bit is visible in: a panel centred in its cell looks the same
		# whichever edge you claim it turns on.
		if base == Blocks.DOOR:
			return [_mid_slab(lo, hi, df, DOOR_THICK)]
		return [_slab_toward(lo, hi, dh, DOOR_THICK)]
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
## The box a torch actually occupies inside its cell, in cell-local space.
##
## Shared with the selection outline so the highlight hugs the post rather than
## the cell it stands in -- and shared rather than copied, because two
## descriptions of the same stick drift apart the first time one is tuned.
static func torch_box(up: Vector3) -> Array:
	var a := _half_toward(Vector3.ZERO, Vector3.ONE, -up)
	var a0: Vector3 = a[0]
	var a1: Vector3 = a[1]
	var mid: Vector3 = (a0 + a1) * 0.5
	var thin := Vector3(0.16, 0.16, 0.16)
	if absf(up.x) > 0.5: thin.x = (a1.x - a0.x) * 0.5
	elif absf(up.y) > 0.5: thin.y = (a1.y - a0.y) * 0.5
	else: thin.z = (a1.z - a0.z) * 0.5
	return [mid - thin, mid + thin]


## A thin slice down the MIDDLE of a cell, across the given axis.
static func _mid_slab(lo: Vector3, hi: Vector3, dir: Vector3, t: float) -> Array:
	var l := lo
	var h := hi
	var d := (hi - lo) * t * 0.5
	var c := (lo + hi) * 0.5
	if absf(dir.x) > 0.5:
		l.x = c.x - d.x
		h.x = c.x + d.x
	elif absf(dir.y) > 0.5:
		l.y = c.y - d.y
		h.y = c.y + d.y
	else:
		l.z = c.z - d.z
		h.z = c.z + d.z
	return [l, h]


## A thin slice of a cell against one of its faces. _half_toward with the
## fraction spelled out, for the one shape that is not a half of anything.
static func _slab_toward(lo: Vector3, hi: Vector3, dir: Vector3, t: float) -> Array:
	var l := lo
	var h := hi
	var d := (hi - lo) * t
	if dir.x > 0.5: l.x = h.x - d.x
	elif dir.x < -0.5: h.x = l.x + d.x
	elif dir.y > 0.5: l.y = h.y - d.y
	elif dir.y < -0.5: h.y = l.y + d.y
	elif dir.z > 0.5: l.z = h.z - d.z
	elif dir.z < -0.5: h.z = l.z + d.z
	return [l, h]


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


## How full a water cell is, 0..1. The floor is there because a cell holding an
## eighth of a cell of water still has to be visible from the side.
static func _water_h(wsnap: Dictionary, gv: Vector3i) -> float:
	return clampf(float(int(wsnap.get(gv, Planet.W_FULL))) / float(Planet.W_FULL), 0.12, 1.0)


## One cell of water: a box as tall as the water in it, wearing only the faces
## that something can actually see.
##
## The interesting case is a water NEIGHBOUR. Skipping that face outright -- the
## rule that is right for solid blocks -- is wrong here, because two cells of
## water are rarely the same depth: where this one stands taller than the one
## beside it, the difference is a wall of water with nothing drawn on it, and you
## see straight through the side of the stream. That is the seam between levels.
## So a shared face is drawn for the BAND this cell has and its neighbour does
## not, and skipped only when the neighbour is at least as deep.
static func _emit_water_cell(clo: Vector3, gv: Vector3i, up: Vector3, h: float,
		planet: Planet, snap: Dictionary, wsnap: Dictionary,
		wverts: PackedVector3Array, wnormals: PackedVector3Array,
		wcolors: PackedColorArray, wuvs: PackedVector2Array, wuv2s: PackedVector2Array,
		wetfall: PackedVector3Array = PackedVector3Array()) -> void:
	var base := planet.color_of(Blocks.WATER)
	var chi := clo + Vector3.ONE
	# The axis water fills along, and which end of the cell it fills from.
	var ax := 0 if absf(up.x) > 0.5 else (1 if absf(up.y) > 0.5 else 2)
	var rising := up[ax] > 0.0
	var upi := Vector3i(int(round(up.x)), int(round(up.y)), int(round(up.z)))
	for fi in 6:
		var n: Vector3i = _WFACE[fi]
		var wnid := _id_at(planet, snap, gv + n)
		var air := wnid == Blocks.AIR or Blocks.is_leaf(Blocks.bottom_of(wnid))
		# Somewhere for this cell to go. Recorded once per cell, and only for
		# real air -- leaves are drawn through, not fallen through.
		if wnid == Blocks.AIR and (wetfall.is_empty() or wetfall[wetfall.size() - 1] != Vector3(gv)):
			wetfall.append(Vector3(gv))
		# The bottom of this face, as a fraction up the cell. Zero unless a
		# neighbouring body of water already covers the lower part of it.
		var from := 0.0
		if not air:
			if wnid != Blocks.WATER:
				continue          # solid: nothing of this face is visible
			var hn := _water_h(wsnap, gv + n)
			if n == upi:
				# Water directly above. Only a cell that is not brim-full has
				# any surface left to show under it.
				if h >= 0.999:
					continue
			elif n == -upi:
				# Water below, hanging short of this cell's floor.
				if hn >= 0.999:
					continue
			else:
				if hn >= h - 0.001:
					continue      # the neighbour is as deep or deeper
				from = hn
		var lo := clo
		var hi := chi
		if rising:
			hi[ax] = clo[ax] + h
			lo[ax] = clo[ax] + from
		else:
			lo[ax] = chi[ax] - h
			hi[ax] = chi[ax] - from
		var s := _face_shade(fi / 2, 1 if (fi % 2) == 0 else -1)
		# Water keeps its OWN alpha. Unlike terrain, water is drawn with a plain
		# StandardMaterial3D that reads vertex alpha as opacity -- so writing the
		# skylight into that channel (which is what terrain does with it) made every
		# lit surface of water fully opaque. An opaque sheet at render distance
		# reads as a chunk that has not loaded.
		#
		# Daylight still gets to darken deep or roofed-over water; it just does it
		# through the COLOUR rather than through the alpha.
		var sky := _sky_depth(snap, gv + n)
		var lit := s * lerpf(0.4, 1.0, sky)
		var col := Color(base.r * lit, base.g * lit, base.b * lit, base.a)
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


## The mesh for an item's picture: this block on its own, every face showing.
##
## Built HERE rather than wherever the icons are drawn, because everything it
## needs is here -- the shape a block occupies inside its cell, the per-face
## shading, and the exact vertex layout the block shader reads its id, its
## orientation and its light out of. An icon that guessed at that layout would
## be a picture of a different-looking block, which is worse than a coloured
## square: it would be confidently wrong.
##
## Centred on the origin and one unit across, so whatever photographs it can
## point a camera at nothing in particular and get the whole thing.
static func icon_mesh(raw: int, col: Color) -> ArrayMesh:
	var verts := PackedVector3Array()
	var normals := PackedVector3Array()
	var colors := PackedColorArray()
	var uvs := PackedVector2Array()
	var uv2s := PackedVector2Array()
	# Up is plain +Y here. On a planet it is whichever axis the cell faces, but
	# an icon is not standing anywhere -- and a slab drawn lying down is what a
	# slab looks like.
	var boxes := shape_boxes(raw, Vector3.UP)
	if boxes.is_empty():
		boxes = [[Vector3.ZERO, Vector3.ONE]]
	# A half-height block is described by build_mesh_data rather than by
	# shape_boxes, so it is repeated here -- the one shape that would otherwise
	# come out a full cube and quietly lie about what you are carrying.
	if raw == Blocks.ROOF_SLAB or Blocks.is_slab(raw) or Blocks.is_stacked_slab(raw):
		boxes = [[Vector3.ZERO, Vector3(1.0, 0.5, 1.0)]]
	var half := Vector3(0.5, 0.5, 0.5)
	for b in boxes:
		var lo: Vector3 = (b[0] as Vector3) - half
		var hi: Vector3 = (b[1] as Vector3) - half
		for fi in 6:
			var n: Vector3i = _WFACE[fi]
			var sh := _face_shade(fi / 2, 1 if (fi % 2) == 0 else -1)
			# Alpha is DAYLIGHT, not opacity (see _quad). An icon is always in
			# the open, so it is always full.
			var c := Color(col.r * sh, col.g * sh, col.b * sh, 1.0)
			var q := _box_face(lo, hi, fi)
			_quad(q[0], q[1], q[2], q[3], Vector3(n), c,
				verts, normals, colors, uvs, uv2s, raw, sh, 0.0)
	var arr := []
	arr.resize(Mesh.ARRAY_MAX)
	arr[Mesh.ARRAY_VERTEX] = verts
	arr[Mesh.ARRAY_NORMAL] = normals
	arr[Mesh.ARRAY_COLOR] = colors
	arr[Mesh.ARRAY_TEX_UV] = uvs
	arr[Mesh.ARRAY_TEX_UV2] = uv2s
	var mesh := ArrayMesh.new()
	mesh.add_surface_from_arrays(Mesh.PRIMITIVE_TRIANGLES, arr)
	return mesh


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
		base: Vector3i, ids: PackedInt32Array, bslot: PackedByteArray, strides: Array,
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
	# The region each face belongs to. In the merge key for the same reason
	# daylight is: one quad can otherwise run out of a meadow and across a moor
	# and take a single colour for the whole thing, which puts the border
	# between two regions wherever the merge happened to stop rather than where
	# the ground actually changes.
	var bmask := PackedInt32Array()
	bmask.resize(CS * CS)
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
					# Leaf against leaf draws ONE quad, not none and not two.
					#
					# Two coplanar quads at the same depth under cull_disabled
					# z-fight across the whole canopy, so this used to drop both --
					# which hollowed every tree out, leaving a shell one block thick
					# with nothing behind the gaps in it. Keeping only the face from
					# the lower cell of the pair (dir > 0) leaves exactly one quad
					# per boundary: no z-fighting, and the leaves inside the canopy
					# show through the holes in the ones outside it.
					if _SEETHRU[nlow] == 1 and not (
							_LEAF[nlow] == 1 and _LEAF[oid & Blocks.ID_MASK] == 1
							and dir < 0):
						val = oid
				mask[k + j * CS] = val
				bmask[k + j * CS] = bslot[lin] if val != 0 else 0
				smask[k + j * CS] = 15
				if val != 0:
					# Sampled at the cell the face LOOKS INTO, not at the block
					# itself. Daylight reaches a surface through the air in front of
					# it: measuring from inside the block meant the wall of a shaft
					# you dug found its own solid neighbours overhead and went pitch
					# black, while the open shaft it faced was letting light down.
					smask[k + j * CS] = int(round(_sky_depth(snap,
						_global_coord(base, d, u, v, a, k, j)
						+ Vector3i(int(narr[0]), int(narr[1]), int(narr[2]))) * 15.0))
				lmask[k + j * CS] = 0
				if val != 0 and has_light:
					lmask[k + j * CS] = int(round(_face_light(snap,
						_global_coord(base, d, u, v, a, k, j),
						Vector3i(int(narr[0]), int(narr[1]), int(narr[2]))) * 15.0))

		var w_coord := a + (1 if dir > 0 else 0)
		_emit_mask(planet, snap, mask, lmask, smask, bmask, d, u, v, dir, w_coord, normal,
			verts, normals, colors, wverts, wnormals, wcolors, uvs, wuvs, uv2s, wuv2s,
			cverts, base)


# Opaque blocks use their registry colour, except procedural ores, whose colour is
# defined by the planet (each world's ores look different).
## How much daylight reaches this voxel: a lookup into the map flood-filled by
## _compute_skylight, which the build fills in before any meshing happens.
static func _sky_depth(snap: Dictionary, gv: Vector3i) -> float:
	var sk = snap.get(SKY_KEY)
	if sk == null:
		return 1.0
	var l: Vector3i = gv - (snap[SKY_ORG] as Vector3i)
	if l.x < 0 or l.y < 0 or l.z < 0 			or l.x >= SKY_DIM or l.y >= SKY_DIM or l.z >= SKY_DIM:
		return 0.0
	return float((sk as PackedByteArray)[_sky_index(l.x, l.y, l.z)]) / float(SKY_MAX)


static func _block_color(planet: Planet, id: int, slot: int = 0) -> Color:
	# Ore blocks are meshed as STONE. The ore itself is drawn by the shader as
	# chunks embedded in that stone (colour supplied per planet via uniforms),
	# rather than the whole block being one flat ore colour.
	if Blocks.is_ore(id):
		return planet.color_of(planet.pal_rock)
	# Per-planet, not per-registry: the block id stays global so recipes and
	# inventories are unchanged, while what you see belongs to this world. And
	# per-REGION for the ground, so a meadow and a moor are different greens of
	# the same soil rather than the same green twice.
	return planet.ground_color(id, slot)


static func _emit_mask(planet: Planet, snap: Dictionary, mask: PackedInt32Array,
		lmask: PackedInt32Array, smask: PackedInt32Array, bmask: PackedInt32Array,
		d: int, u: int, v: int, dir: int, w_coord: int,
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
			var bv := bmask[k + j * CS]
			var wdt := 1
			while k + wdt < CS and mask[k + wdt + j * CS] == val 					and lmask[k + wdt + j * CS] == lv and smask[k + wdt + j * CS] == sv 					and bmask[k + wdt + j * CS] == bv:
				wdt += 1
			var hgt := 1
			var stop := false
			while j + hgt < CS and not stop:
				for x in wdt:
					if mask[k + x + (j + hgt) * CS] != val 							or lmask[k + x + (j + hgt) * CS] != lv 							or smask[k + x + (j + hgt) * CS] != sv 							or bmask[k + x + (j + hgt) * CS] != bv:
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
			var bcol := _block_color(planet, val, bv)
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
## Fixed shading per face direction, baked into the vertex colour.
##
## This is what makes a blocky world READ as blocky. The old values spanned 0.86
## to 1.0, which is a 14% difference between a floor and a wall -- at any
## distance the ground turned into one flat sheet and a terrace edge or a step
## disappeared into it. Every block game uses a much wider spread than looks
## reasonable written down, and the two horizontal axes differ from each other on
## purpose: it is the only cue that tells you which way a corner turns.
##
## The sun's own directional light is on top of this, but it cannot do the job
## alone -- it moves, and half the time it is somewhere that leaves the faces you
## are looking at equally lit.
static func _face_shade(d: int, dir: int) -> float:
	if d == 1:  # Y axis: sky above, ground below
		return 1.0 if dir > 0 else 0.55
	if d == 0:  # X axis
		return 0.74 if dir > 0 else 0.70
	return 0.88 if dir > 0 else 0.82  # Z axis


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
