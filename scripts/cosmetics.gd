class_name Cosmetics
extends RefCounted
## Things to wear that change nothing but how you look.
##
## Seven slots -- hat, face, shirt, pants, shoes, back and trail -- and every
## piece is found, never made: they turn up in the chests of wrecks, outposts,
## ruins and vaults, each kind of site with its own sort of thing (a wreck has
## flight gear, a ruin old-world finery, a vault the rare ones).
##
## Everything worn is 3D, over the body rather than painted onto the skin: a
## shirt is a shell a little bigger than the torso with sleeves on the arms, a
## pair of trousers a shell on each leg, and hats, glasses, shoes and whatever
## hangs on your back small pieces fixed where they belong. The parts that
## move -- sleeves, trouser legs, shoes -- ride on the limbs, so they swing when
## you walk. The skin underneath is never touched. A trail is particles.
##
## Every piece is its own item id, from FIRST_ID up, so two different hats
## never stack into one.

const SLOTS := ["hat", "face", "shirt", "pants", "shoes", "back", "trail"]
const SLOT_NAMES := {"hat": "Hat", "face": "Face", "shirt": "Shirt", "pants": "Pants",
	"shoes": "Shoes", "back": "Back", "trail": "Trail"}
const FIRST_ID := 141

## Where each 3D slot is fixed, on RemotePlayer's figure (whose origin is the
## body's centre and whose front faces -Z).
const HEAD_TOP := Vector3(0, 1.02, 0)
const HEAD_FRONT := Vector3(0, 0.81, -0.21)
const BACK := Vector3(0, 0.24, 0.215)   # just behind a shirt, not inside it
const SOLE := Vector3(0, -0.78, 0)     # on each leg's hip pivot

const C_RED := Color(0.78, 0.16, 0.14)
const C_BLACK := Color(0.07, 0.07, 0.08)
const C_WHITE := Color(0.93, 0.93, 0.9)
const C_GOLD := Color(0.95, 0.75, 0.18)
const C_BROWN := Color(0.42, 0.26, 0.14)
const C_DENIM := Color(0.2, 0.3, 0.58)
const C_KHAKI := Color(0.68, 0.6, 0.4)
const C_NAVY := Color(0.1, 0.13, 0.3)
const C_GREEN := Color(0.18, 0.5, 0.28)
const C_ORANGE := Color(0.95, 0.5, 0.12)
const C_TEAL := Color(0.15, 0.6, 0.65)
const C_PINK := Color(0.95, 0.45, 0.65)
const C_GLASS := Color(0.7, 0.88, 1.0, 0.32)

## [key, slot, name, sites it is found at, look]
## Sites: "w" wreck, "o" outpost, "r" ruin, "v" vault.
## Most looks are "boxes": [position, size, colour] from the slot's anchor.
## Shirts and trousers are "clothes", made into boxes by clothes_boxes -- they
## are fitted to the body, so they are described by colour and cut rather than
## box by box. Trails are particles.
const ITEMS := [
	# --- hats ---------------------------------------------------------------
	["cap", "hat", "Red Cap", "o", {"boxes": [
		[Vector3(0, 0.05, 0.01), Vector3(0.48, 0.1, 0.44), C_RED],
		[Vector3(0, 0.01, -0.3), Vector3(0.32, 0.03, 0.2), C_RED]]}],
	["beanie", "hat", "Beanie", "o", {"boxes": [
		[Vector3(0, 0.05, 0), Vector3(0.49, 0.14, 0.45), C_GREEN],
		[Vector3(0, -0.03, 0), Vector3(0.5, 0.07, 0.46), Color(0.12, 0.36, 0.2)],
		[Vector3(0, 0.15, 0), Vector3(0.1, 0.07, 0.1), C_WHITE]]}],
	["top_hat", "hat", "Top Hat", "r", {"boxes": [
		[Vector3(0, 0.015, 0), Vector3(0.68, 0.03, 0.64), C_BLACK],
		[Vector3(0, 0.25, 0), Vector3(0.42, 0.44, 0.4), C_BLACK],
		[Vector3(0, 0.07, 0), Vector3(0.43, 0.07, 0.41), C_RED]]}],
	["cowboy", "hat", "Cowboy Hat", "ro", {"boxes": [
		[Vector3(0, 0.015, 0), Vector3(0.84, 0.03, 0.74), C_BROWN],
		[Vector3(0, 0.13, 0), Vector3(0.44, 0.22, 0.4), C_BROWN],
		[Vector3(0, 0.05, 0), Vector3(0.45, 0.05, 0.41), C_BLACK]]}],
	["crown", "hat", "Crown", "v", {"boxes": [
		[Vector3(0, 0.05, 0), Vector3(0.5, 0.1, 0.46), C_GOLD],
		[Vector3(-0.2, 0.14, -0.18), Vector3(0.08, 0.1, 0.08), C_GOLD],
		[Vector3(0.2, 0.14, -0.18), Vector3(0.08, 0.1, 0.08), C_GOLD],
		[Vector3(-0.2, 0.14, 0.18), Vector3(0.08, 0.1, 0.08), C_GOLD],
		[Vector3(0.2, 0.14, 0.18), Vector3(0.08, 0.1, 0.08), C_GOLD],
		[Vector3(0, 0.05, -0.235), Vector3(0.08, 0.06, 0.02), C_RED]]}],
	["party_hat", "hat", "Party Hat", "o", {"boxes": [
		[Vector3(0, 0.06, 0), Vector3(0.32, 0.12, 0.32), C_PINK],
		[Vector3(0, 0.18, 0), Vector3(0.22, 0.12, 0.22), C_TEAL],
		[Vector3(0, 0.3, 0), Vector3(0.13, 0.12, 0.13), C_PINK],
		[Vector3(0, 0.4, 0), Vector3(0.06, 0.08, 0.06), C_GOLD]]}],
	["space_helmet", "hat", "Space Helmet", "wv", {"boxes": [
		[Vector3(0, -0.21, 0), Vector3(0.62, 0.58, 0.58), C_GLASS],
		[Vector3(0, -0.47, 0), Vector3(0.6, 0.08, 0.56), C_WHITE]]}],
	# --- face ---------------------------------------------------------------
	["sunglasses", "face", "Sunglasses", "ow", {"boxes": [
		[Vector3(-0.1, 0.03, -0.01), Vector3(0.15, 0.08, 0.02), C_BLACK],
		[Vector3(0.1, 0.03, -0.01), Vector3(0.15, 0.08, 0.02), C_BLACK],
		[Vector3(0, 0.05, -0.01), Vector3(0.08, 0.02, 0.02), C_BLACK]]}],
	["goggles", "face", "Goggles", "rw", {"boxes": [
		[Vector3(0, 0.04, 0.21), Vector3(0.48, 0.05, 0.44), C_BROWN],
		[Vector3(-0.1, 0.04, -0.02), Vector3(0.14, 0.11, 0.04), C_ORANGE],
		[Vector3(0.1, 0.04, -0.02), Vector3(0.14, 0.11, 0.04), C_ORANGE]]}],
	["visor", "face", "Visor", "w", {"boxes": [
		[Vector3(0, 0.04, -0.02), Vector3(0.5, 0.1, 0.03), Color(0.3, 0.95, 1.0, 0.6)],
		[Vector3(0, 0.04, 0.21), Vector3(0.49, 0.04, 0.43), C_WHITE]]}],
	["mustache", "face", "Mustache", "r", {"boxes": [
		[Vector3(0, -0.07, -0.01), Vector3(0.22, 0.04, 0.02), C_BROWN],
		[Vector3(-0.12, -0.09, -0.01), Vector3(0.05, 0.05, 0.02), C_BROWN],
		[Vector3(0.12, -0.09, -0.01), Vector3(0.05, 0.05, 0.02), C_BROWN]]}],
	["bandana", "face", "Bandana", "o", {"boxes": [
		[Vector3(0, -0.1, -0.01), Vector3(0.48, 0.17, 0.02), C_RED],
		[Vector3(0, -0.2, -0.015), Vector3(0.16, 0.06, 0.02), C_RED]]}],
	# --- shirts: a shell on the torso, sleeves on the arms ------------------
	["tee", "shirt", "T-Shirt", "o", {"clothes": {"color": C_WHITE, "sleeve": 0.35}}],
	["hoodie", "shirt", "Hoodie", "o", {"clothes": {"color": Color(0.35, 0.36, 0.4), "sleeve": 1.0,
		"cuff": Color(0.22, 0.23, 0.26)}}],
	["striped", "shirt", "Striped Shirt", "or", {"clothes": {"color": C_NAVY, "sleeve": 0.35,
		"stripes": C_WHITE}}],
	["flight_jacket", "shirt", "Flight Jacket", "w", {"clothes": {"color": Color(0.36, 0.4, 0.24),
		"sleeve": 1.0, "collar": Color(0.5, 0.33, 0.18), "cuff": Color(0.5, 0.33, 0.18)}}],
	["tuxedo", "shirt", "Tuxedo", "rv", {"clothes": {"color": C_BLACK, "sleeve": 1.0,
		"front": C_WHITE}}],
	["tropical", "shirt", "Tropical Shirt", "o", {"clothes": {"color": C_ORANGE, "sleeve": 0.35,
		"dots": C_TEAL}}],
	# --- trousers: a shell on each leg, and a waistband ---------------------
	["jeans", "pants", "Jeans", "o", {"clothes": {"color": C_DENIM, "leg": 1.0}}],
	["cargo_shorts", "pants", "Cargo Shorts", "o", {"clothes": {"color": C_KHAKI, "leg": 0.5}}],
	["striped_trousers", "pants", "Striped Trousers", "r", {"clothes": {"color": Color(0.3, 0.12, 0.15),
		"leg": 1.0, "stripes": Color(0.55, 0.3, 0.3)}}],
	["space_pants", "pants", "Flight Suit Trousers", "w", {"clothes": {"color": C_WHITE, "leg": 1.0,
		"side": C_ORANGE}}],
	# --- shoes: one per leg -------------------------------------------------
	["boots", "shoes", "Boots", "wr", {"boxes": [
		[Vector3(0, 0.11, -0.01), Vector3(0.27, 0.22, 0.31), C_BROWN],
		[Vector3(0, 0.02, -0.03), Vector3(0.28, 0.04, 0.34), C_BLACK]]}],
	["sneakers", "shoes", "Sneakers", "o", {"boxes": [
		[Vector3(0, 0.06, -0.03), Vector3(0.27, 0.12, 0.34), C_WHITE],
		[Vector3(0, 0.08, -0.03), Vector3(0.28, 0.03, 0.35), C_RED]]}],
	["sandals", "shoes", "Sandals", "o", {"boxes": [
		[Vector3(0, 0.02, -0.03), Vector3(0.27, 0.04, 0.33), C_BROWN]]}],
	# --- back ---------------------------------------------------------------
	["cape", "back", "Cape", "rv", {"boxes": [
		[Vector3(0, -0.1, 0.03), Vector3(0.62, 0.95, 0.03), C_RED],
		[Vector3(0, 0.34, 0.02), Vector3(0.66, 0.05, 0.05), C_GOLD]]}],
	["backpack", "back", "Backpack", "o", {"boxes": [
		[Vector3(0, 0.0, 0.1), Vector3(0.44, 0.52, 0.2), C_GREEN],
		[Vector3(0, -0.12, 0.21), Vector3(0.3, 0.18, 0.04), Color(0.12, 0.36, 0.2)]]}],
	["jetpack", "back", "Jetpack", "wv", {"boxes": [
		[Vector3(-0.12, 0.02, 0.1), Vector3(0.15, 0.52, 0.15), Color(0.6, 0.62, 0.66)],
		[Vector3(0.12, 0.02, 0.1), Vector3(0.15, 0.52, 0.15), Color(0.6, 0.62, 0.66)],
		[Vector3(-0.12, -0.28, 0.1), Vector3(0.1, 0.08, 0.1), C_ORANGE],
		[Vector3(0.12, -0.28, 0.1), Vector3(0.1, 0.08, 0.1), C_ORANGE]]}],
	["wings", "back", "Wings", "v", {"boxes": [
		[Vector3(-0.38, 0.1, 0.06), Vector3(0.5, 0.56, 0.03), C_WHITE],
		[Vector3(0.38, 0.1, 0.06), Vector3(0.5, 0.56, 0.03), C_WHITE],
		[Vector3(-0.56, 0.3, 0.06), Vector3(0.18, 0.2, 0.03), C_WHITE],
		[Vector3(0.56, 0.3, 0.06), Vector3(0.18, 0.2, 0.03), C_WHITE]]}],
	# --- trails: particles --------------------------------------------------
	["sparkles", "trail", "Sparkle Trail", "v", {"trail": {"color": C_GOLD, "rise": -0.4}}],
	["embers", "trail", "Ember Trail", "rv", {"trail": {"color": C_ORANGE, "rise": 1.4}}],
	["bubbles", "trail", "Bubble Trail", "wv", {"trail": {"color": Color(0.6, 0.9, 1.0, 0.7), "rise": 0.8}}],
	["hearts", "trail", "Pink Trail", "o", {"trail": {"color": C_PINK, "rise": 0.3}}],
]


static var _by_key := {}
static var _by_id := {}


static func _index() -> void:
	if not _by_id.is_empty():
		return
	for i in ITEMS.size():
		var row: Array = ITEMS[i]
		var d := {"key": row[0], "slot": row[1], "name": row[2], "sites": row[3],
			"look": row[4], "id": FIRST_ID + i}
		_by_key[row[0]] = d
		_by_id[FIRST_ID + i] = d


static func is_cosmetic(id: int) -> bool:
	return id >= FIRST_ID and id < FIRST_ID + ITEMS.size()


static func def_of(id: int) -> Dictionary:
	_index()
	return _by_id.get(id, {})


static func by_key(key: String) -> Dictionary:
	_index()
	return _by_key.get(key, {})


static func slot_of(id: int) -> String:
	return str(def_of(id).get("slot", ""))


static func name_of(id: int) -> String:
	return str(def_of(id).get("name", "Cosmetic"))


## The colour an item's square is drawn in before its picture arrives.
static func color_of(id: int) -> Color:
	var look: Dictionary = def_of(id).get("look", {})
	if look.has("clothes"):
		return look["clothes"]["color"]
	if look.has("trail"):
		return look["trail"]["color"]
	if look.has("boxes") and not (look["boxes"] as Array).is_empty():
		return look["boxes"][0][2]
	return Color.WHITE


## Everything a kind of site can hold, as item ids. `site` is Sites.WRECK etc.
static func pool_for(site: int) -> Array:
	_index()
	var ch: String = ["w", "o", "r", "v"][site]
	var out: Array = []
	for i in ITEMS.size():
		if (ITEMS[i][3] as String).contains(ch):
			out.append(FIRST_ID + i)
	return out


# --- drawing it on a body -----------------------------------------------------

## Where the fitted parts sit, relative to RemotePlayer's figure. The torso
## and hips go on the body; sleeves on each shoulder pivot; trouser legs on each
## hip pivot, so they move with the limb inside them.
const TORSO := Vector3(0, 0.24, 0)
const SHOULDER := Vector3(0.40, 0.57, 0)      # x mirrored for the other arm
const HIP := Vector3(0.17, -0.12, 0)          # likewise
## How much bigger than the body part a garment is, so it sits over it rather
## than fighting it for the same surface.
const FIT := 0.04


## A shirt or pair of trousers as boxes, sorted by what they hang from:
## {"torso": [...], "arm": [...], "leg": [...]}, each in its part's own space.
static func clothes_boxes(id: int) -> Dictionary:
	var d := def_of(id)
	var c: Dictionary = d.get("look", {}).get("clothes", {})
	var out := {"torso": [], "arm": [], "leg": []}
	if c.is_empty():
		return out
	var col: Color = c["color"]
	if str(d["slot"]) == "shirt":
		var tw := 0.62 + FIT
		var th := 0.72 + FIT
		var td := 0.38 + FIT
		if c.has("stripes"):
			# Bands down the torso, alternating.
			var n := 7
			for i in n:
				var y0 := th * 0.5 - th * float(i) / n
				var bc: Color = c["stripes"] if i % 2 == 1 else col
				out["torso"].append([Vector3(0, y0 - th / n * 0.5, 0), Vector3(tw, th / n, td), bc])
		else:
			out["torso"].append([Vector3.ZERO, Vector3(tw, th, td), col])
		if c.has("front"):
			# A shirt front down the middle, and a bow at the neck.
			out["torso"].append([Vector3(0, 0, -td * 0.5 - 0.004), Vector3(0.14, th, 0.01), c["front"]])
			out["torso"].append([Vector3(0, th * 0.5 - 0.06, -td * 0.5 - 0.01), Vector3(0.14, 0.05, 0.02), C_BLACK])
		if c.has("collar"):
			out["torso"].append([Vector3(0, th * 0.5 - 0.02, 0), Vector3(tw * 0.8, 0.06, td + 0.02), c["collar"]])
		if c.has("dots"):
			for p in [Vector2(-0.18, 0.2), Vector2(0.12, 0.25), Vector2(-0.05, 0.02),
					Vector2(0.2, -0.12), Vector2(-0.2, -0.2), Vector2(0.05, -0.28)]:
				out["torso"].append([Vector3(p.x, p.y, -td * 0.5 - 0.005), Vector3(0.08, 0.08, 0.01), c["dots"]])
				out["torso"].append([Vector3(-p.x, p.y, td * 0.5 + 0.005), Vector3(0.08, 0.08, 0.01), c["dots"]])
		var sl := float(c.get("sleeve", 1.0))
		var al := 0.66 * sl + FIT * 0.5
		out["arm"].append([Vector3(0, -al * 0.5 + FIT * 0.5, 0), Vector3(0.18 + FIT, al, 0.26 + FIT), col])
		if c.has("cuff"):
			out["arm"].append([Vector3(0, -al + FIT * 0.5 + 0.025, 0), Vector3(0.18 + FIT + 0.01, 0.05, 0.27 + FIT), c["cuff"]])
	else:
		var lg := float(c.get("leg", 1.0))
		var ll := 0.78 * lg + FIT * 0.5
		if c.has("stripes"):
			var n := maxi(int(round(6 * lg)), 2)
			for i in n:
				var bc: Color = c["stripes"] if i % 2 == 1 else col
				out["leg"].append([Vector3(0, -ll * (float(i) + 0.5) / n + FIT * 0.5, 0),
					Vector3(0.24 + FIT, ll / n, 0.28 + FIT), bc])
		else:
			out["leg"].append([Vector3(0, -ll * 0.5 + FIT * 0.5, 0), Vector3(0.24 + FIT, ll, 0.28 + FIT), col])
		if c.has("side"):
			out["leg"].append([Vector3(0.12 + FIT * 0.5, -ll * 0.5 + FIT * 0.5, 0), Vector3(0.01, ll, 0.06), c["side"]])
		# The waistband, on the body, closing the gap between trousers and shirt.
		out["torso"].append([Vector3(0, -0.36 + 0.05, 0), Vector3(0.62 + FIT, 0.1, 0.38 + FIT), col])
	return out


## A 3D piece as one mesh, its boxes relative to where it is worn.
static func piece_mesh(id: int) -> ArrayMesh:
	var boxes: Array = def_of(id).get("look", {}).get("boxes", [])
	return _boxes_mesh(boxes, Vector3.ZERO, 1.0)


static func _boxes_mesh(boxes: Array, shift: Vector3, scale: float) -> ArrayMesh:
	var st := SurfaceTool.new()
	st.begin(Mesh.PRIMITIVE_TRIANGLES)
	var clear := false
	for b in boxes:
		var c: Color = b[2]
		clear = clear or c.a < 0.99
		var p0: Vector3 = ((b[0] as Vector3) - (b[1] as Vector3) * 0.5 + shift) * scale
		var p1: Vector3 = ((b[0] as Vector3) + (b[1] as Vector3) * 0.5 + shift) * scale
		for fi in 6:
			var s := Chunk._face_shade(fi / 2, 1 if (fi % 2) == 0 else -1)
			st.set_color(Color(c.r * s, c.g * s, c.b * s, c.a))
			st.set_normal(Vector3(Chunk._WFACE[fi]))
			var q := Chunk._box_face(p0, p1, fi)
			st.add_vertex(q[0]); st.add_vertex(q[1]); st.add_vertex(q[2])
			st.add_vertex(q[0]); st.add_vertex(q[2]); st.add_vertex(q[3])
	var m := st.commit()
	if m.get_surface_count() > 0:
		var mat := StandardMaterial3D.new()
		mat.vertex_color_use_as_albedo = true
		mat.cull_mode = BaseMaterial3D.CULL_DISABLED
		mat.roughness = 0.9
		if clear:
			mat.transparency = BaseMaterial3D.TRANSPARENCY_ALPHA
		m.surface_set_material(0, mat)
	return m


## A trail: particles that fall off you as you move, in the world rather than
## on you, so they are left behind where you have been.
static func make_trail(id: int) -> CPUParticles3D:
	var t: Dictionary = def_of(id).get("look", {}).get("trail", {})
	if t.is_empty():
		return null
	var ps := CPUParticles3D.new()
	var box := BoxMesh.new()
	box.size = Vector3.ONE * 0.07
	var m := StandardMaterial3D.new()
	m.shading_mode = BaseMaterial3D.SHADING_MODE_UNSHADED
	m.vertex_color_use_as_albedo = true
	m.transparency = BaseMaterial3D.TRANSPARENCY_ALPHA
	box.material = m
	ps.mesh = box
	ps.amount = 40
	ps.lifetime = 1.4
	ps.local_coords = false
	ps.emission_shape = CPUParticles3D.EMISSION_SHAPE_BOX
	ps.emission_box_extents = Vector3(0.25, 0.1, 0.25)
	ps.direction = Vector3.UP
	ps.spread = 60.0
	ps.initial_velocity_min = 0.2
	ps.initial_velocity_max = 0.6
	ps.gravity = Vector3.UP * float(t.get("rise", 0.0))
	ps.scale_amount_min = 0.6
	ps.scale_amount_max = 1.3
	var c: Color = t["color"]
	var ramp := Gradient.new()
	ramp.set_color(0, Color(c.r, c.g, c.b, c.a))
	ramp.set_color(1, Color(c.r, c.g, c.b, 0.0))
	ps.color_ramp = ramp
	ps.emitting = false
	return ps


## The item's picture: the piece itself where it has one, a stand-in shape for
## particles. Fitted into the unit cube ItemIcon photographs.
static func icon_mesh(id: int) -> ArrayMesh:
	var d := def_of(id)
	var look: Dictionary = d.get("look", {})
	var boxes: Array = []
	if look.has("boxes"):
		boxes = look["boxes"]
	elif look.has("clothes"):
		# The garment laid out as it is worn: torso with its sleeves, or both
		# trouser legs with their waistband.
		var cb := clothes_boxes(id)
		for b in cb["torso"]:
			boxes.append(b)
		for side in [1.0, -1.0]:
			var sh := SHOULDER * Vector3(side, 1, 1) - TORSO
			for b in cb["arm"]:
				boxes.append([(b[0] as Vector3) * Vector3(side, 1, 1) + sh, b[1], b[2]])
			var hp := HIP * Vector3(side, 1, 1) - TORSO
			for b in cb["leg"]:
				boxes.append([(b[0] as Vector3) * Vector3(side, 1, 1) + hp, b[1], b[2]])
	elif look.has("trail"):
		var tc: Color = look["trail"]["color"]
		tc.a = 1.0
		boxes = [[Vector3(-0.2, -0.15, 0), Vector3(0.14, 0.14, 0.14), tc],
			[Vector3(0.05, 0.05, 0.1), Vector3(0.18, 0.18, 0.18), tc],
			[Vector3(0.25, 0.25, -0.1), Vector3(0.1, 0.1, 0.1), tc],
			[Vector3(-0.05, 0.3, -0.15), Vector3(0.08, 0.08, 0.08), tc]]
	if boxes.is_empty():
		return null
	var lo := Vector3(1e9, 1e9, 1e9)
	var hi := -lo
	for b in boxes:
		lo = lo.min((b[0] as Vector3) - (b[1] as Vector3) * 0.5)
		hi = hi.max((b[0] as Vector3) + (b[1] as Vector3) * 0.5)
	var ext := hi - lo
	var s := 1.0 / maxf(maxf(ext.x, ext.y), maxf(ext.z, 0.001))
	return _boxes_mesh(boxes, -(lo + hi) * 0.5, s)
