class_name ToolModels
extends RefCounted
## What tools look like: a few boxes each, handle along +Y with the working end
## at the top and pointing forward (-Z), the way they are held.
##
## One description serves both places a tool is seen -- in your hand and as its
## picture in the bag -- so the two can never disagree.

const HANDLE := Color(0.45, 0.30, 0.16)
const GRIP := Color(0.22, 0.2, 0.19)
const STONE := Color(0.55, 0.55, 0.57)
const STEEL := Color(0.72, 0.74, 0.78)


static func has_model(id: int) -> bool:
	return not boxes_for(id, Color.WHITE).is_empty()


## Held by a handle standing up, rather than pointing forward like a drill.
static func is_upright(id: int) -> bool:
	return id in [Blocks.PICK, Blocks.AXE, Blocks.SPADE, Blocks.HOE, Blocks.WEAPON, Blocks.SWORD]


## [position, size, colour] boxes for the tool, or [] if it has no model.
## `tint` is the material's own colour, for what is made of it.
static func boxes_for(id: int, tint: Color) -> Array:
	# A bucket is thin walls round a hole; thickened it is just a cube.
	if id == Blocks.BUCKET or id == Blocks.WATER_BUCKET:
		return _boxes(id, tint)
	var out: Array = []
	for b in _boxes(id, tint):
		out.append([b[0], _beef(b[1]), b[2]])
	return out


## Everything a bit chunkier than drawn below: thin parts (handles, blades)
## thickened the most, so a tool reads as solid rather than as a wire.
static func _beef(sz: Vector3) -> Vector3:
	var o := sz
	for a in 3:
		o[a] = sz[a] * 1.15 + 0.022
	return o


static func _boxes(id: int, tint: Color) -> Array:
	match id:
		Blocks.PICK:
			return [
				[Vector3(0, 0.0, 0), Vector3(0.045, 0.56, 0.045), HANDLE],
				[Vector3(0, 0.27, 0), Vector3(0.07, 0.07, 0.4), STONE],
				[Vector3(0, 0.25, -0.22), Vector3(0.05, 0.05, 0.07), STONE],
				[Vector3(0, 0.25, 0.22), Vector3(0.05, 0.05, 0.07), STONE],
				[Vector3(0, 0.22, -0.26), Vector3(0.04, 0.05, 0.04), STONE]]
		Blocks.AXE:
			return [
				[Vector3(0, 0.0, 0), Vector3(0.045, 0.56, 0.045), HANDLE],
				[Vector3(0, 0.23, -0.08), Vector3(0.05, 0.14, 0.13), STONE],
				[Vector3(0, 0.23, -0.16), Vector3(0.035, 0.2, 0.05), STONE],
				[Vector3(0, 0.25, 0.04), Vector3(0.055, 0.06, 0.06), STONE]]
		Blocks.SPADE:
			return [
				[Vector3(0, -0.02, 0), Vector3(0.045, 0.5, 0.045), HANDLE],
				[Vector3(0, -0.28, 0), Vector3(0.12, 0.04, 0.05), HANDLE],
				[Vector3(0, 0.26, 0), Vector3(0.06, 0.08, 0.06), STONE],
				[Vector3(0, 0.37, 0), Vector3(0.025, 0.16, 0.16), STONE],
				[Vector3(0, 0.47, 0), Vector3(0.025, 0.05, 0.1), STONE]]
		Blocks.HOE:
			return [
				[Vector3(0, 0.0, 0), Vector3(0.045, 0.56, 0.045), HANDLE],
				[Vector3(0, 0.27, -0.06), Vector3(0.06, 0.05, 0.16), STONE],
				[Vector3(0, 0.22, -0.13), Vector3(0.12, 0.08, 0.03), STONE]]
		Blocks.DRILL:
			return [
				[Vector3(0, -0.12, 0.04), Vector3(0.08, 0.2, 0.1), GRIP],
				[Vector3(0, 0.02, 0.0), Vector3(0.14, 0.14, 0.32), Color(0.3, 0.3, 0.32)],
				[Vector3(0, 0.02, -0.2), Vector3(0.09, 0.09, 0.08), tint],
				[Vector3(0, 0.02, -0.3), Vector3(0.05, 0.05, 0.12), tint],
				[Vector3(0, 0.02, -0.39), Vector3(0.025, 0.025, 0.06), tint]]
		Blocks.SWORD:
			return [
				[Vector3(0, -0.24, 0), Vector3(0.045, 0.2, 0.045), HANDLE],
				[Vector3(0, -0.35, 0), Vector3(0.06, 0.04, 0.06), HANDLE],
				[Vector3(0, -0.12, 0), Vector3(0.17, 0.035, 0.04), HANDLE],
				[Vector3(0, 0.15, 0), Vector3(0.07, 0.5, 0.03), STONE],
				[Vector3(0, 0.43, 0), Vector3(0.04, 0.06, 0.03), STONE]]
		Blocks.WEAPON:
			return [
				[Vector3(0, -0.14, 0), Vector3(0.05, 0.22, 0.05), Color(0.25, 0.22, 0.2)],
				[Vector3(0, 0.0, 0), Vector3(0.16, 0.03, 0.05), Color(0.35, 0.32, 0.3)],
				[Vector3(0, 0.3, 0), Vector3(0.05, 0.55, 0.02), tint],
				[Vector3(0, 0.6, 0), Vector3(0.03, 0.05, 0.02), tint]]
		Blocks.PULSE_PISTOL:
			return [
				[Vector3(0, -0.14, 0.02), Vector3(0.08, 0.16, 0.1), Color(0.2, 0.2, 0.22)],
				[Vector3(0, 0, -0.08), Vector3(0.1, 0.09, 0.3), Color(0.28, 0.28, 0.3)],
				[Vector3(0, 0.01, -0.28), Vector3(0.05, 0.05, 0.14), tint]]
		Blocks.BUCKET, Blocks.WATER_BUCKET:
			var out := [
				[Vector3(0, 0, 0), Vector3(0.2, 0.02, 0.2), STEEL],
				[Vector3(0, 0.1, -0.1), Vector3(0.22, 0.2, 0.02), STEEL],
				[Vector3(0, 0.1, 0.1), Vector3(0.22, 0.2, 0.02), STEEL],
				[Vector3(-0.1, 0.1, 0), Vector3(0.02, 0.2, 0.2), STEEL],
				[Vector3(0.1, 0.1, 0), Vector3(0.02, 0.2, 0.2), STEEL],
				[Vector3(0, 0.26, 0), Vector3(0.18, 0.015, 0.015), Color(0.4, 0.4, 0.42)]]
			if id == Blocks.WATER_BUCKET:
				out.append([Vector3(0, 0.16, 0), Vector3(0.18, 0.02, 0.18), Color(0.2, 0.45, 0.85)])
			return out
	return []


## The tool as one mesh, as held.
static func mesh(id: int, tint: Color) -> ArrayMesh:
	var boxes := boxes_for(id, tint)
	if boxes.is_empty():
		return null
	return Cosmetics._boxes_mesh(boxes, Vector3.ZERO, 1.0)


## The same, fitted into the unit cube ItemIcon photographs.
static func icon_mesh(id: int, tint: Color) -> ArrayMesh:
	var boxes: Array = []
	# Chunkier than life: at the size of a bag slot a real handle is a hairline.
	for b in boxes_for(id, tint):
		var sz: Vector3 = b[1]
		boxes.append([b[0], sz.max(Vector3.ONE * 0.075), b[2]])
	if boxes.is_empty():
		return null
	var lo := Vector3(1e9, 1e9, 1e9)
	var hi := -lo
	for b in boxes:
		lo = lo.min((b[0] as Vector3) - (b[1] as Vector3) * 0.5)
		hi = hi.max((b[0] as Vector3) + (b[1] as Vector3) * 0.5)
	var ext := hi - lo
	var s := 1.0 / maxf(maxf(ext.x, ext.y), maxf(ext.z, 0.001))
	return Cosmetics._boxes_mesh(boxes, -(lo + hi) * 0.5, s)
