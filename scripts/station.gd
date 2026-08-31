class_name Station
extends StaticBody3D

## A placed crafting machine (Smelter / Fabricator / Shipworks). Unlike terrain and
## ships it is not voxel data -- it's a single standalone body you look at and open
## with E. Each station carries its own internal storage grid; the player moves
## items between it and their inventory. Phase 1 implements the Smelter (refine raw
## ore into an identified refined material).

const STORAGE_SLOTS := 8      # machines
const CHEST_SLOTS := 24       # chests hold more
const MAX_SLOTS := 24         # UI builds this many cells

var kind: int = Blocks.SMELTER
var world: WorldManager
var storage: Array = []           # slots: {id, count, props, src, mat}

var _mi: MeshInstance3D
var _col: CollisionShape3D


static func capacity_of(k: int) -> int:
	return CHEST_SLOTS if k == Blocks.CHEST else STORAGE_SLOTS


func capacity() -> int:
	return capacity_of(kind)


func _init() -> void:
	_ensure_storage()


# (Re)size storage to this station's capacity, preserving existing slots.
func _ensure_storage() -> void:
	var cap := capacity()
	while storage.size() < cap:
		storage.append({"id": Blocks.AIR, "count": 0, "props": {}, "src": "", "mat": {}})
	if storage.size() > cap:
		storage.resize(cap)


func configure(k: int, w: WorldManager) -> void:
	kind = k
	world = w
	_ensure_storage()
	_build_visual()


func title() -> String:
	return Blocks.name_of(kind)


func _ready() -> void:
	if _mi == null:
		_build_visual()


func _build_visual() -> void:
	if _mi == null:
		_mi = MeshInstance3D.new()
		add_child(_mi)
	if _col == null:
		_col = CollisionShape3D.new()
		add_child(_col)
	var box := BoxMesh.new()
	box.size = Vector3(0.96, 0.96, 0.96)
	_mi.mesh = box
	_mi.position = Vector3(0.5, 0.5, 0.5)  # centered in the cell it was placed in
	var mat := StandardMaterial3D.new()
	var c := Blocks.color_of(kind)
	mat.albedo_color = c
	if kind == Blocks.CHEST:  # a chest is a crate, not a glowing machine
		mat.roughness = 0.8
		mat.metallic = 0.0
	else:
		mat.roughness = 0.5
		mat.metallic = 0.4
		mat.emission_enabled = true
		mat.emission = c.lerp(Color(1, 0.7, 0.3), 0.5)
		mat.emission_energy_multiplier = 0.35
	_mi.material_override = mat
	var shape := BoxShape3D.new()
	shape.size = Vector3.ONE
	_col.shape = shape
	_col.position = Vector3(0.5, 0.5, 0.5)


# --- storage helpers ----------------------------------------------------------

## Add items to internal storage; returns leftover that didn't fit.
func store_add(id: int, n: int, props: Dictionary = {}, src: String = "", mat: Dictionary = {}) -> int:
	if id == Blocks.AIR or n <= 0:
		return n
	for s in storage:
		if s["count"] > 0 and s["id"] == id and s.get("src", "") == src:
			s["count"] += n
			return 0
	for s in storage:
		if s["count"] == 0:
			s["id"] = id
			s["count"] = n
			s["props"] = props
			s["src"] = src
			s["mat"] = mat
			return 0
	return n  # full


## Smelt every raw-ore slot into its refined material, keeping its identity/props
## (which the tooltip now reveals). Returns how many slots were refined.
func refine_all() -> int:
	var done := 0
	for s in storage:
		if s["count"] > 0 and Blocks.is_ore(s["id"]):
			var refined := Blocks.refined_of(s["id"])
			if refined != Blocks.AIR:
				s["id"] = refined
				done += 1
	return done
