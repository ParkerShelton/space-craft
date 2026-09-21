class_name PatternPicture
extends Node
## A picture of a machine you build from blocks, for the Recipe Book.
##
## The book used to print these as letters -- rows of W and S and dots, with a
## key that half the patterns did not even include -- and working out a shape
## from that was a puzzle in its own right. This renders the finished build as
## a little 3D model instead: the same cells the game checks your build against,
## in the colours of the materials, seen from above and to one side.
##
## Works like ItemIcon: `of` hands back a texture at once and fills it in a
## frame or two later, one picture per frame, each taken once and kept.

const SIZE := Vector2i(176, 136)
const YAW := 0.7
const PITCH := 0.55

static var _inst: PatternPicture
var _cache := {}      # pattern name -> ImageTexture
var _queue: Array = []
var _busy := false
var _vp: SubViewport
var _mi: MeshInstance3D
var _cam: Camera3D


static func of(def: Dictionary) -> ImageTexture:
	var me := _instance()
	if me == null:
		return null
	var key := str(def["name"])
	var got = me._cache.get(key)
	if got != null:
		return got
	var img := Image.create(SIZE.x, SIZE.y, false, Image.FORMAT_RGBA8)
	img.fill(Color(0, 0, 0, 0))
	var tex := ImageTexture.create_from_image(img)
	me._cache[key] = tex
	me._queue.append([def, tex])
	return tex


static func _instance() -> PatternPicture:
	if _inst != null and is_instance_valid(_inst):
		return _inst
	var tree := Engine.get_main_loop() as SceneTree
	if tree == null:
		return null
	_inst = PatternPicture.new()
	_inst.name = "PatternPictures"
	tree.root.add_child(_inst)
	return _inst


func _ready() -> void:
	_vp = SubViewport.new()
	_vp.size = SIZE
	_vp.transparent_bg = true
	_vp.render_target_update_mode = SubViewport.UPDATE_DISABLED
	_vp.own_world_3d = true
	add_child(_vp)
	var env := WorldEnvironment.new()
	var e := Environment.new()
	e.ambient_light_source = Environment.AMBIENT_SOURCE_COLOR
	e.ambient_light_color = Color(1, 1, 1)
	e.ambient_light_energy = 0.9
	env.environment = e
	_vp.add_child(env)
	var sun := DirectionalLight3D.new()
	sun.rotation_degrees = Vector3(-48, 30, 0)
	sun.light_energy = 0.6
	_vp.add_child(sun)
	_mi = MeshInstance3D.new()
	_vp.add_child(_mi)
	_cam = Camera3D.new()
	_cam.projection = Camera3D.PROJECTION_ORTHOGONAL
	_cam.near = 0.01
	_cam.far = 60.0
	_vp.add_child(_cam)


func _process(_delta: float) -> void:
	if _busy or _queue.is_empty():
		return
	_busy = true
	_shoot(_queue.pop_front())


func _shoot(job: Array) -> void:
	var def: Dictionary = job[0]
	var built := _build_mesh(def)
	_mi.mesh = built[0]
	var lo: Vector3 = built[1]
	var hi: Vector3 = built[2]
	var mid := (lo + hi) * 0.5
	var ext := (hi - lo).length()
	_cam.size = maxf(ext * 1.05, 0.5)
	var dir := Vector3(cos(PITCH) * sin(YAW), sin(PITCH), cos(PITCH) * cos(YAW))
	_cam.look_at_from_position(mid + dir * (ext + 4.0), mid, Vector3.UP)
	_vp.render_target_update_mode = SubViewport.UPDATE_ONCE
	await RenderingServer.frame_post_draw
	await RenderingServer.frame_post_draw
	var tex: ImageTexture = job[1]
	if is_instance_valid(tex):
		tex.set_image(_vp.get_texture().get_image())
	_busy = false


## The build as boxes, one per filled cell, with the faces between two filled
## cells left out. [mesh, lo corner, hi corner].
static func _build_mesh(def: Dictionary) -> Array:
	var cells := Blocks.pattern_cells(def)
	var cell := 1.0 if def.has("legend") else 0.5
	var st := SurfaceTool.new()
	st.begin(Mesh.PRIMITIVE_TRIANGLES)
	var lo := Vector3(1e9, 1e9, 1e9)
	var hi := -lo
	for c in cells:
		var id: int = cells[c]
		var col := Blocks.color_of(id)
		var p0 := Vector3(c) * cell
		var p1 := p0 + Vector3.ONE * cell
		lo = lo.min(p0)
		hi = hi.max(p1)
		for fi in 6:
			var n: Vector3i = Chunk._WFACE[fi]
			if cells.has(c + n):
				continue
			var s := Chunk._face_shade(fi / 2, 1 if (fi % 2) == 0 else -1)
			st.set_color(Color(col.r * s, col.g * s, col.b * s))
			st.set_normal(Vector3(n))
			var q := Chunk._box_face(p0, p1, fi)
			st.add_vertex(q[0]); st.add_vertex(q[1]); st.add_vertex(q[2])
			st.add_vertex(q[0]); st.add_vertex(q[2]); st.add_vertex(q[3])
	var m := st.commit()
	var mat := StandardMaterial3D.new()
	mat.vertex_color_use_as_albedo = true
	mat.cull_mode = BaseMaterial3D.CULL_DISABLED
	mat.roughness = 1.0
	if m.get_surface_count() > 0:
		m.surface_set_material(0, mat)
	if cells.is_empty():
		lo = Vector3.ZERO
		hi = Vector3.ONE
	return [m, lo, hi]
