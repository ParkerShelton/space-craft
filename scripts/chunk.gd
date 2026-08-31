class_name Chunk
extends StaticBody3D

## One 16^3 slab of a planet. The heavy work -- greedy meshing -- is a static,
## thread-safe pure function (build_mesh_data) that touches no scene state, so it
## can run on a WorkerThreadPool. The main thread then calls apply_mesh_data to
## turn the raw arrays into an ArrayMesh + collision shape.

const CS := Blocks.CHUNK_SIZE

var planet: Planet
var cc: Vector3i  # chunk coordinate (in chunk units)

var _mesh_instance: MeshInstance3D
var _collision: CollisionShape3D

static var _material: StandardMaterial3D


static var _water_material: StandardMaterial3D

static func _get_material() -> StandardMaterial3D:
	if _material == null:
		_material = StandardMaterial3D.new()
		_material.vertex_color_use_as_albedo = true
		_material.cull_mode = BaseMaterial3D.CULL_DISABLED  # render both sides; robust vs winding
		_material.roughness = 0.85
		_material.metallic = 0.0
	return _material


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
		return

	var m := ArrayMesh.new()
	if not verts.is_empty():
		var arr := []
		arr.resize(Mesh.ARRAY_MAX)
		arr[Mesh.ARRAY_VERTEX] = verts
		arr[Mesh.ARRAY_NORMAL] = data["normals"]
		arr[Mesh.ARRAY_COLOR] = data["colors"]
		m.add_surface_from_arrays(Mesh.PRIMITIVE_TRIANGLES, arr)
		m.surface_set_material(m.get_surface_count() - 1, _get_material())
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

	# collision uses only the opaque geometry -- you pass through water
	if verts.is_empty():
		_collision.shape = null
	else:
		var shape := ConcavePolygonShape3D.new()
		shape.backface_collision = true
		shape.set_faces(verts)
		_collision.shape = shape


# --- background thread: pure greedy mesher ------------------------------------
#
# `snap` maps Vector3i(global voxel) -> block id for any player edits in this
# chunk and its face-neighbors. Everything else comes from planet.generation_sample
# (a pure read of noise), so this function is safe to run off the main thread.

static func _id_at(planet: Planet, snap: Dictionary, v: Vector3i) -> int:
	if snap.has(v):
		return snap[v]
	return planet.generation_sample(v.x, v.y, v.z)


static func build_mesh_data(planet: Planet, cc: Vector3i, snap: Dictionary) -> Dictionary:
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
				if id != Blocks.AIR:
					any_solid = true
				i += 1

	# opaque geometry (surface 0, collidable) and water geometry (surface 1, see-through)
	var verts := PackedVector3Array()
	var normals := PackedVector3Array()
	var colors := PackedColorArray()
	var wverts := PackedVector3Array()
	var wnormals := PackedVector3Array()
	var wcolors := PackedColorArray()
	if not any_solid:
		return {"verts": verts, "normals": normals, "colors": colors,
			"wverts": wverts, "wnormals": wnormals, "wcolors": wcolors}

	var strides := [1, CS, CS * CS]
	for d in 3:
		var u := (d + 1) % 3
		var v := (d + 2) % 3
		for dir in [1, -1]:
			_greedy_pass(planet, snap, d, u, v, dir, base, ids, strides,
				verts, normals, colors, wverts, wnormals, wcolors)

	return {"verts": verts, "normals": normals, "colors": colors,
		"wverts": wverts, "wnormals": wnormals, "wcolors": wcolors}


static func _greedy_pass(planet: Planet, snap: Dictionary, d: int, u: int, v: int, dir: int,
		base: Vector3i, ids: PackedInt32Array, strides: Array,
		verts: PackedVector3Array, normals: PackedVector3Array, colors: PackedColorArray,
		wverts: PackedVector3Array, wnormals: PackedVector3Array, wcolors: PackedColorArray) -> void:
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
				if oid != Blocks.AIR:
					var na := a + dir
					var nid: int
					if na >= 0 and na < CS:
						nid = ids[na * sd + k * su + row]
					else:
						nid = _id_at(planet, snap, _global_coord(base, d, u, v, na, k, j))
					# Water is see-through: draw a face if the neighbor is air; opaque
					# blocks also draw against water (so the seabed shows under it).
					var draw: bool
					if oid == Blocks.WATER:
						draw = nid == Blocks.AIR
					else:
						draw = nid == Blocks.AIR or nid == Blocks.WATER
					if draw:
						val = oid
				mask[k + j * CS] = val

		var w_coord := a + (1 if dir > 0 else 0)
		_emit_mask(mask, d, u, v, dir, w_coord, normal,
			verts, normals, colors, wverts, wnormals, wcolors)


static func _emit_mask(mask: PackedInt32Array, d: int, u: int, v: int, dir: int, w_coord: int,
		normal: Vector3,
		verts: PackedVector3Array, normals: PackedVector3Array, colors: PackedColorArray,
		wverts: PackedVector3Array, wnormals: PackedVector3Array, wcolors: PackedColorArray) -> void:
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
			var base := Blocks.color_of(val)
			var col := Color(base.r * s, base.g * s, base.b * s, base.a)  # keep alpha (water)
			var p00 := _corner(d, u, v, w_coord, k, j)
			var p10 := _corner(d, u, v, w_coord, k + wdt, j)
			var p11 := _corner(d, u, v, w_coord, k + wdt, j + hgt)
			var p01 := _corner(d, u, v, w_coord, k, j + hgt)
			if val == Blocks.WATER:
				if dir > 0:
					_quad(p00, p10, p11, p01, normal, col, wverts, wnormals, wcolors)
				else:
					_quad(p00, p01, p11, p10, normal, col, wverts, wnormals, wcolors)
			else:
				if dir > 0:
					_quad(p00, p10, p11, p01, normal, col, verts, normals, colors)
				else:
					_quad(p00, p01, p11, p10, normal, col, verts, normals, colors)
			k += wdt


static func _quad(a: Vector3, b: Vector3, c: Vector3, e: Vector3, normal: Vector3, col: Color,
		verts: PackedVector3Array, normals: PackedVector3Array, colors: PackedColorArray) -> void:
	verts.append(a); verts.append(b); verts.append(c)
	verts.append(a); verts.append(c); verts.append(e)
	for _n in 6:
		normals.append(normal)
		colors.append(col)


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
