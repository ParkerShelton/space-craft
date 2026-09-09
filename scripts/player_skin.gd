class_name PlayerSkin
extends RefCounted

## Where a player's appearance lives: the texture layout, and the meshes that
## read from it.
##
## The layout is the classic 64x64 humanoid one -- head, body, two arms, two
## legs, each with six faces laid out in a cross. It is used here for a reason
## beyond familiarity: it is the format every skin anybody already owns is in,
## so an existing file can be dropped in and worn without conversion. Nothing
## about the rest of the game depends on the choice; it is a table of rectangles.
##
## Sizes below are in TEXELS, not metres. The avatar's boxes are their own
## proportions (see RemotePlayer) and each face simply stretches its rectangle
## to fit, which is what lets a layout designed for one set of proportions dress
## a different one.

const ATLAS := 64

## Which way the figure faces. The avatar's eyes sit on -Z, so -Z is its front,
## and its own right hand is therefore on -X. Getting this wrong mirrors every
## skin -- the seam up the back ends up down the front -- so it is written down
## once here rather than rediscovered per part.
const FRONT := Vector3i(0, 0, -1)

## part -> face -> Rect2i(x, y, w, h) in the atlas.
##
## Faces are named for the FIGURE, not for the axes: "right" is the figure's
## right, which is a viewer's left. The classic layout's arm and leg regions are
## laid out for the right limb, with the left mirrored into its own block, which
## is why left and right are separate entries rather than one shared.
const LAYOUT := {
	"head": {
		"top":    Rect2i(8, 0, 8, 8),
		"bottom": Rect2i(16, 0, 8, 8),
		"right":  Rect2i(0, 8, 8, 8),
		"front":  Rect2i(8, 8, 8, 8),
		"left":   Rect2i(16, 8, 8, 8),
		"back":   Rect2i(24, 8, 8, 8),
	},
	"body": {
		"top":    Rect2i(20, 16, 8, 4),
		"bottom": Rect2i(28, 16, 8, 4),
		"right":  Rect2i(16, 20, 4, 12),
		"front":  Rect2i(20, 20, 8, 12),
		"left":   Rect2i(28, 20, 4, 12),
		"back":   Rect2i(32, 20, 8, 12),
	},
	"right_arm": {
		"top":    Rect2i(44, 16, 4, 4),
		"bottom": Rect2i(48, 16, 4, 4),
		"right":  Rect2i(40, 20, 4, 12),
		"front":  Rect2i(44, 20, 4, 12),
		"left":   Rect2i(48, 20, 4, 12),
		"back":   Rect2i(52, 20, 4, 12),
	},
	"left_arm": {
		"top":    Rect2i(36, 48, 4, 4),
		"bottom": Rect2i(40, 48, 4, 4),
		"right":  Rect2i(32, 52, 4, 12),
		"front":  Rect2i(36, 52, 4, 12),
		"left":   Rect2i(40, 52, 4, 12),
		"back":   Rect2i(44, 52, 4, 12),
	},
	"right_leg": {
		"top":    Rect2i(4, 16, 4, 4),
		"bottom": Rect2i(8, 16, 4, 4),
		"right":  Rect2i(0, 20, 4, 12),
		"front":  Rect2i(4, 20, 4, 12),
		"left":   Rect2i(8, 20, 4, 12),
		"back":   Rect2i(12, 20, 4, 12),
	},
	"left_leg": {
		"top":    Rect2i(20, 48, 4, 4),
		"bottom": Rect2i(24, 48, 4, 4),
		"right":  Rect2i(16, 52, 4, 12),
		"front":  Rect2i(20, 52, 4, 12),
		"left":   Rect2i(24, 52, 4, 12),
		"back":   Rect2i(28, 52, 4, 12),
	},
}

const PARTS := ["head", "body", "right_arm", "left_arm", "right_leg", "left_leg"]


## A box with the six faces of one part mapped onto it.
##
## Built by hand rather than with BoxMesh because BoxMesh gives every face the
## same 0..1 UVs -- the same picture six times over, which is a box wearing one
## tile rather than a figure wearing a skin.
static func part_mesh(part: String, size: Vector3) -> ArrayMesh:
	var faces: Dictionary = LAYOUT.get(part, LAYOUT["body"])
	var h := size * 0.5
	var verts := PackedVector3Array()
	var norms := PackedVector3Array()
	var uvs := PackedVector2Array()

	# Corner order per face is chosen so the texture reads the right way up and
	# the right way round when seen from outside that face.
	_quad(verts, norms, uvs, faces["front"],
		Vector3(h.x, h.y, -h.z), Vector3(-h.x, h.y, -h.z),
		Vector3(-h.x, -h.y, -h.z), Vector3(h.x, -h.y, -h.z), Vector3(0, 0, -1))
	_quad(verts, norms, uvs, faces["back"],
		Vector3(-h.x, h.y, h.z), Vector3(h.x, h.y, h.z),
		Vector3(h.x, -h.y, h.z), Vector3(-h.x, -h.y, h.z), Vector3(0, 0, 1))
	# The figure's right is -X, so -X takes the "right" rectangle.
	_quad(verts, norms, uvs, faces["right"],
		Vector3(-h.x, h.y, -h.z), Vector3(-h.x, h.y, h.z),
		Vector3(-h.x, -h.y, h.z), Vector3(-h.x, -h.y, -h.z), Vector3(-1, 0, 0))
	_quad(verts, norms, uvs, faces["left"],
		Vector3(h.x, h.y, h.z), Vector3(h.x, h.y, -h.z),
		Vector3(h.x, -h.y, -h.z), Vector3(h.x, -h.y, h.z), Vector3(1, 0, 0))
	_quad(verts, norms, uvs, faces["top"],
		Vector3(-h.x, h.y, h.z), Vector3(h.x, h.y, h.z),
		Vector3(h.x, h.y, -h.z), Vector3(-h.x, h.y, -h.z), Vector3(0, 1, 0))
	_quad(verts, norms, uvs, faces["bottom"],
		Vector3(-h.x, -h.y, -h.z), Vector3(h.x, -h.y, -h.z),
		Vector3(h.x, -h.y, h.z), Vector3(-h.x, -h.y, h.z), Vector3(0, -1, 0))

	var arr := []
	arr.resize(Mesh.ARRAY_MAX)
	arr[Mesh.ARRAY_VERTEX] = verts
	arr[Mesh.ARRAY_NORMAL] = norms
	arr[Mesh.ARRAY_TEX_UV] = uvs
	var mesh := ArrayMesh.new()
	mesh.add_surface_from_arrays(Mesh.PRIMITIVE_TRIANGLES, arr)
	return mesh


## One face: two triangles, and the atlas rectangle stretched across them.
##
## The rectangle is inset by a fraction of a texel. Sampling exactly on the edge
## of a rect picks up its neighbour on the other side of the seam, which shows
## as a one-pixel fringe of the wrong body part along every edge of every face.
static func _quad(verts: PackedVector3Array, norms: PackedVector3Array,
		uvs: PackedVector2Array, r: Rect2i,
		a: Vector3, b: Vector3, c: Vector3, d: Vector3, n: Vector3) -> void:
	const INSET := 0.01
	var u0 := (float(r.position.x) + INSET) / ATLAS
	var v0 := (float(r.position.y) + INSET) / ATLAS
	var u1 := (float(r.position.x + r.size.x) - INSET) / ATLAS
	var v1 := (float(r.position.y + r.size.y) - INSET) / ATLAS
	# Corner and its texture coordinate together, then emitted by index. Listing
	# the two in parallel is how they drift apart: the winding was reversed here
	# once already, and every face of every part was being culled as a result --
	# the figure was inside out, and what you saw was the far wall of a hollow
	# box, which reads as a shape collapsing into a wedge.
	var corners := [
		[a, Vector2(u0, v0)], [b, Vector2(u1, v0)],
		[c, Vector2(u1, v1)], [d, Vector2(u0, v1)],
	]
	# Whichever way round actually faces outward, worked out from the corners
	# rather than trusted to whoever typed them. Listing four corners the other
	# way round is easy to do and invisible in code -- it cost every top and
	# bottom face on the figure, after the same mistake had already cost all
	# twenty-four of the others.
	var order := [0, 2, 1, 0, 3, 2]
	if (c - a).cross(b - a).dot(n) < 0.0:
		order = [0, 1, 2, 0, 2, 3]
	for i in order:
		verts.append((corners[i] as Array)[0])
		uvs.append((corners[i] as Array)[1])
		norms.append(n)


## Nearest-neighbour, unshaded-ish, and lit by the world.
##
## Filtering is the one setting that matters: a skin is pixel art, and a linear
## filter turns a hand-placed pixel into a smudge. Everything else here just
## matches how the rest of the game's surfaces behave.
static func make_material(tex: Texture2D) -> StandardMaterial3D:
	var mat := StandardMaterial3D.new()
	mat.albedo_texture = tex
	mat.texture_filter = BaseMaterial3D.TEXTURE_FILTER_NEAREST
	mat.roughness = 0.85
	mat.metallic = 0.0
	mat.specular = 0.0
	return mat


## Turn a skin image into something a material can wear.
static func texture_from(img: Image) -> ImageTexture:
	return ImageTexture.create_from_image(img)


## An empty skin: fully transparent, ATLAS square, RGBA8.
static func blank_image() -> Image:
	var img := Image.create(ATLAS, ATLAS, false, Image.FORMAT_RGBA8)
	img.fill(Color(0, 0, 0, 0))
	return img


## The skin everybody starts in.
##
## Built rather than shipped as a file so it can be derived from a HUE: the game
## already gave each player a stable colour from their peer id, and keeping that
## as the default means nobody's figure changes appearance the day skins arrive
## -- they simply become editable.
static func default_image(hue: float) -> Image:
	var img := blank_image()
	var body := Color.from_hsv(hue, 0.55, 0.85)
	var trim := Color.from_hsv(hue, 0.65, 0.55)
	var dark := Color.from_hsv(hue, 0.60, 0.42)
	for part in PARTS:
		var col: Color = body if part == "body" else trim
		var faces: Dictionary = LAYOUT[part]
		for f in faces:
			var r: Rect2i = faces[f]
			# Top and bottom a shade darker, so the figure still reads as solid
			# under flat light rather than as a silhouette.
			var c: Color = dark if (f == "top" or f == "bottom") else col
			img.fill_rect(r, c)
	_draw_face(img, Color(0.05, 0.05, 0.06))
	return img


## Eyes, on the head's front rectangle. They used to be two boxes stuck to the
## head; on a skin they are four pixels, which is what makes a skin worth having.
static func _draw_face(img: Image, ink: Color) -> void:
	var f: Rect2i = LAYOUT["head"]["front"]
	for dx in [2, 5]:
		img.set_pixel(f.position.x + dx, f.position.y + 3, ink)
		img.set_pixel(f.position.x + dx, f.position.y + 4, ink)


# --- saved skins --------------------------------------------------------------
#
# One PNG per skin in a folder of its own, named by the player. A file rather
# than a blob in the settings because a skin IS a picture: it can be opened in
# any editor, sent to somebody, or dropped in from elsewhere, and none of that
# works if it lives inside a config file as base64.

const DIR := "user://skins"


static func skins_dir() -> String:
	DirAccess.make_dir_recursive_absolute(DIR)
	return DIR


## Every saved skin, by name, alphabetical.
static func list_skins() -> PackedStringArray:
	var out := PackedStringArray()
	var d := DirAccess.open(skins_dir())
	if d == null:
		return out
	for f in d.get_files():
		if f.to_lower().ends_with(".png"):
			out.append(f.substr(0, f.length() - 4))
	out.sort()
	return out


static func skin_path(name: String) -> String:
	return "%s/%s.png" % [skins_dir(), name]


## Load one by name, or null if it is missing or not a skin-shaped image.
static func load_skin(name: String):
	var path := skin_path(name)
	if not FileAccess.file_exists(path):
		return null
	var img := Image.load_from_file(path)
	if img == null:
		return null
	# Anything can be dropped into that folder, including a photograph. Only
	# accept squares of the right size rather than stretching whatever turns up.
	if img.get_width() != ATLAS or img.get_height() != ATLAS:
		return null
	img.convert(Image.FORMAT_RGBA8)
	return img


static func save_skin(name: String, img: Image) -> bool:
	return img.save_png(skin_path(name)) == OK


static func delete_skin(name: String) -> void:
	var d := DirAccess.open(skins_dir())
	if d != null:
		d.remove("%s.png" % name)


## A name nobody is using yet, based on `base`.
static func free_name(base: String) -> String:
	var taken := {}
	for n in list_skins():
		taken[n] = true
	if not taken.has(base):
		return base
	var i := 2
	while taken.has("%s %d" % [base, i]):
		i += 1
	return "%s %d" % [base, i]


# --- portrait -----------------------------------------------------------------

## The figure seen from the front, assembled out of the skin's own front faces.
##
## Drawn from the atlas rather than rendered in 3D on purpose: it is what the
## skin IS, at exactly its own resolution, with no camera, lighting or angle in
## the way. A menu wants to show you which skin this is, not what it looks like
## in a particular light.
##
## The arrangement is the classic proportions -- 16 texels across by 32 down --
## because those are the shapes the layout's rectangles already are.
const PORTRAIT_W := 16
const PORTRAIT_H := 32

static func portrait(img: Image) -> Image:
	var out := Image.create(PORTRAIT_W, PORTRAIT_H, false, Image.FORMAT_RGBA8)
	out.fill(Color(0, 0, 0, 0))
	var place := [
		["head", Vector2i(4, 0)],
		["body", Vector2i(4, 8)],
		["right_arm", Vector2i(0, 8)],
		["left_arm", Vector2i(12, 8)],
		["right_leg", Vector2i(4, 20)],
		["left_leg", Vector2i(8, 20)],
	]
	for e in place:
		var r: Rect2i = LAYOUT[str(e[0])]["front"]
		out.blit_rect(img, r, e[1] as Vector2i)
	return out


## The portrait as a texture, blown up by whole pixels so it stays pixel art.
static func portrait_texture(img: Image, scale: int = 4) -> ImageTexture:
	var p := portrait(img)
	p.resize(PORTRAIT_W * scale, PORTRAIT_H * scale, Image.INTERPOLATE_NEAREST)
	return ImageTexture.create_from_image(p)
