class_name ItemIcon
extends Node

## Pictures of the things you are carrying.
##
## Blocks are PHOTOGRAPHED rather than drawn. Everything an icon of a block
## needs already exists: the shape the mesher knows it occupies, the colour the
## planet tinted it, and voxel_block.gdshader, which invents that material's
## surface detail from world position. A hand-drawn icon could not reproduce
## that detail without reimplementing the shader, and would go stale the first
## time a world retinted its rock. A photograph of the real thing cannot.
##
## So there is one small viewport off to the side, and items queue up in front
## of it one per frame.

## Pixels square. Big enough that a cube's edges stay crisp when a slot draws it
## at forty-odd, small enough that a few hundred of them are not a texture
## budget.
const SIZE := 96
## How many pictures to keep. Keyed by block AND colour, because an ore's colour
## is the ore -- two worlds' copper are different items to look at.
const MAX_CACHE := 400

## The angle everything is seen from. Turned off-square and tipped down, which
## is the view that shows three faces of a cube at once -- the reason a block
## reads as a block and not as a tile.
const YAW := 0.7
const PITCH := 0.62

static var _inst: ItemIcon

var _vp: SubViewport
var _cam: Camera3D
var _mi: MeshInstance3D
var _cache := {}                 # key -> ImageTexture
var _queue: Array = []           # [key, texture, raw, colour, planet]
var _queued := {}                # key -> true, so nothing is photographed twice
var _busy := false
var _lit := {}                   # planet id -> its material, held at noon


## Is this something we can take a picture of? Blocks and raw material, which is
## everything with a shape or a lump. Tools are still a coloured square: a box
## is not a bucket, and pretending otherwise would be worse than the square.
static func can_draw(raw: int) -> bool:
	if Cosmetics.is_cosmetic(raw) or ToolModels.has_model(raw):
		return true
	var id := Blocks.bottom_of(raw)
	return Blocks.is_placeable_block(id) or Blocks.is_ore(id) 		or Blocks.is_refined(id) or Blocks.is_intermediate(id)


## The picture for this item.
##
## Comes back IMMEDIATELY, as an empty texture that fills itself in a frame or
## two. The caller holds the same texture object either way, so nothing has to
## be told when the picture arrives -- it simply appears.
static func of(raw: int, col: Color, planet: Planet) -> ImageTexture:
	if not can_draw(raw):
		return null
	var me := _instance()
	if me == null:
		return null
	var key := "%d:%s" % [raw, col.to_html(false)]
	var got = me._cache.get(key)
	if got != null:
		return got
	var img := Image.create(SIZE, SIZE, false, Image.FORMAT_RGBA8)
	img.fill(Color(0, 0, 0, 0))
	var tex := ImageTexture.create_from_image(img)
	if me._cache.size() >= MAX_CACHE:
		me._cache.clear()        # simplest thing that bounds it; icons re-take
		me._queued.clear()
	me._cache[key] = tex
	if not me._queued.has(key):
		me._queued[key] = true
		me._queue.append([key, tex, raw, col, planet])
	return tex


static func _instance() -> ItemIcon:
	if _inst != null and is_instance_valid(_inst):
		return _inst
	var tree := Engine.get_main_loop() as SceneTree
	if tree == null:
		return null
	_inst = ItemIcon.new()
	_inst.name = "ItemIcons"
	# Deferred: this is reached from the middle of a UI refresh, and adding a
	# node to the tree during someone else's notification is how you get a
	# "parent is busy" error rather than an icon.
	tree.root.add_child.call_deferred(_inst)
	return _inst


func _ready() -> void:
	_vp = SubViewport.new()
	_vp.size = Vector2i(SIZE, SIZE)
	_vp.transparent_bg = true
	# Nothing renders until an item is actually posed in front of it. A viewport
	# redrawing every frame to photograph nothing is a whole extra frame's work
	# for a picture that has not changed.
	_vp.render_target_update_mode = SubViewport.UPDATE_DISABLED
	# Its own world, or the game's environment decides how these look and these
	# two lights get added to the world the player is standing in.
	_vp.own_world_3d = true
	add_child(_vp)

	var env := WorldEnvironment.new()
	var e := Environment.new()
	e.ambient_light_source = Environment.AMBIENT_SOURCE_COLOR
	e.ambient_light_color = Color(1, 1, 1)
	e.ambient_light_energy = 1.0
	env.environment = e
	_vp.add_child(env)
	# The faces already carry their own shading, baked into the vertex colour by
	# the mesher. This is only enough directional light to keep the shader's own
	# lighting path happy and give the top face a lift.
	var key_light := DirectionalLight3D.new()
	key_light.rotation_degrees = Vector3(-42, 34, 0)
	key_light.light_energy = 1.0
	_vp.add_child(key_light)

	_mi = MeshInstance3D.new()
	_vp.add_child(_mi)

	_cam = Camera3D.new()
	# ORTHOGRAPHIC, which is what makes an icon an icon: no perspective, so the
	# same block is the same size and shape in every slot regardless of where it
	# happens to sit in the frame.
	_cam.projection = Camera3D.PROJECTION_ORTHOGONAL
	# A unit cube seen corner-on is about 1.73 across its longest diagonal;
	# a little over that leaves it room to sit in without touching the edges.
	_cam.size = 1.95
	_cam.near = 0.01
	_cam.far = 10.0
	var dir := Vector3(cos(PITCH) * sin(YAW), sin(PITCH), cos(PITCH) * cos(YAW))
	_cam.position = dir * 4.0
	_cam.look_at_from_position(_cam.position, Vector3.ZERO, Vector3.UP)
	_vp.add_child(_cam)


## The planet's own block material, but always at noon.
##
## The shader takes its ambient from UNIFORMS the day/night cycle drives, not
## from this viewport's environment -- so an icon rendered with the planet's
## live material comes out as dark as the hour it was taken in, and your bag
## would go black at dusk and stay that way until something asked for the
## picture again. A copy of the material with the sky held at full daylight is
## the same material in every other respect: same surface pattern, same
## per-planet seed, same everything you are trying to show.
func _lit_material(planet: Planet) -> Material:
	if planet == null:
		return null
	var live := Chunk._get_material(planet)
	if live == null:
		return null
	var got = _lit.get(planet.get_instance_id())
	if got != null and is_instance_valid(got):
		return got
	var copy: ShaderMaterial = live.duplicate()
	copy.set_shader_parameter("ambient_color", Vector3(0.85, 0.9, 1.0))
	copy.set_shader_parameter("ambient_energy", 1.15)
	_lit[planet.get_instance_id()] = copy
	return copy


func _process(_delta: float) -> void:
	if _busy or _queue.is_empty():
		return
	_busy = true
	_shoot(_queue.pop_front())


## Pose one item and take its picture.
##
## One per frame, deliberately. Opening a full bag asks for forty of these at
## once, and rendering forty viewports in a frame is a visible hitch to fill in
## pictures that arrive perfectly well over the following half second.
func _shoot(job: Array) -> void:
	var raw := int(job[2])
	var col: Color = job[3]
	var planet: Planet = job[4]
	var tool := ToolModels.has_model(raw)
	var worn := Cosmetics.is_cosmetic(raw) or tool
	if tool:
		_mi.mesh = ToolModels.icon_mesh(raw, col)
	else:
		_mi.mesh = Cosmetics.icon_mesh(raw) if Cosmetics.is_cosmetic(raw) else Chunk.icon_mesh(raw, col)
	# Tools lie across the picture, head up and to the right, as they do in
	# every inventory; everything else stands square to the camera.
	# Turned side-on to the camera first, so the head is seen in profile rather
	# than end-on, then leant over; and drawn larger, since lying diagonally it
	# fills the frame corner to corner rather than edge to edge.
	if tool:
		_mi.rotation = Vector3(deg_to_rad(40.0), YAW - PI * 0.5, 0)
		_mi.scale = Vector3.ONE * 1.3
	else:
		_mi.rotation = Vector3.ZERO
		_mi.scale = Vector3.ONE
	# Cosmetics carry their own vertex-colour material, in the mesh.
	var mat: Material = null if worn else _lit_material(planet)
	if mat == null:
		# No planet yet -- out on the menu, or in space. A plain material still
		# reads the vertex colours the mesher baked, so the block keeps its
		# shape and shading and loses only its surface pattern.
		var fallback := StandardMaterial3D.new()
		fallback.vertex_color_use_as_albedo = true
		fallback.roughness = 0.9
		mat = fallback
	_mi.material_override = null if worn else mat
	# Each block sits at its OWN spot in the world, because the shader draws its
	# surface pattern from world position: posed at the same place every time,
	# every material would wear an identical smear of noise.
	_mi.position = Vector3(float(raw) * 4.0, 0.0, 0.0)
	_cam.position = _mi.position + Vector3(
		cos(PITCH) * sin(YAW), sin(PITCH), cos(PITCH) * cos(YAW)) * 4.0
	_cam.look_at_from_position(_cam.position, _mi.position, Vector3.UP)
	_vp.render_target_update_mode = SubViewport.UPDATE_ONCE
	await RenderingServer.frame_post_draw
	var tex: ImageTexture = job[1]
	if is_instance_valid(tex):
		tex.set_image(_vp.get_texture().get_image())
	_busy = false
