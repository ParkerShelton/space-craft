class_name Sites
extends RefCounted
## Things left behind on a world, worth going to find: crashed ships and
## derelict outposts on the surface, ruins and sealed vaults underground, each
## with chests of loot.
##
## Placed like the terrain itself -- a pure function of the world seed -- so
## nothing about them is stored until you have taken something. The planet is
## cut into big cubes (REGION blocks a side) and each cube near the surface
## rolls, from its own position and the seed, whether it holds a site of each
## kind. How LIKELY each kind is gets rolled once per world, and zero is one of
## the answers: some worlds have no wrecks on them at all, and finding that out
## is part of the world.
##
## A site is kept well inside its cube (MARGIN), so the only cube that ever has
## to be asked about a block is the one the block is in.

const REGION := 256
const MARGIN := 70

enum { WRECK, OUTPOST, RUIN, VAULT }
const KIND_NAMES := ["Crashed Ship", "Derelict Outpost", "Ruins", "Vault"]

## Per-world likelihood of each kind in any one region, picked from these.
const DENSITY_CHOICES := {
	WRECK: [0.0, 0.2, 0.4, 0.7],
	OUTPOST: [0.0, 0.0, 0.2, 0.45],
	RUIN: [0.0, 0.25, 0.5, 0.8],
	VAULT: [0.0, 0.15, 0.3],
}

## Minimal loot rows: [id, min, max, chance]. Ores are added separately, from
## the planet's own list (see _fill).
const LOOT := {
	WRECK: [[Blocks.METAL, 3, 10, 0.9], [Blocks.GLASS, 2, 6, 0.5],
		[Blocks.THRUSTER, 1, 2, 0.35], [Blocks.COCKPIT, 1, 1, 0.15],
		[Blocks.LIFE_SUPPORT, 1, 1, 0.2], [Blocks.WARP_DRIVE, 1, 1, 0.06],
		[Blocks.BATTERY, 1, 2, 0.3], [Blocks.WIRE, 4, 12, 0.4],
		[Blocks.GLOW_LAMP, 1, 3, 0.3]],
	OUTPOST: [[Blocks.TORCH, 4, 12, 0.7], [Blocks.GLOW_LAMP, 1, 4, 0.5],
		[Blocks.COOKED_MEAT, 2, 6, 0.6], [Blocks.CLOTH, 2, 6, 0.4],
		[Blocks.PICK, 1, 1, 0.25], [Blocks.AXE, 1, 1, 0.25], [Blocks.SPADE, 1, 1, 0.25],
		[Blocks.METAL, 2, 6, 0.5], [Blocks.BATTERY, 1, 1, 0.2]],
	RUIN: [[Blocks.CRYSTAL, 2, 8, 0.5], [Blocks.TORCH, 3, 8, 0.6],
		[Blocks.BONE, 2, 6, 0.5], [Blocks.GLOW_LAMP, 1, 2, 0.3]],
	VAULT: [[Blocks.WARP_DRIVE, 1, 1, 0.25], [Blocks.BATTERY, 2, 4, 0.5],
		[Blocks.THRUSTER, 1, 3, 0.4], [Blocks.LIFE_SUPPORT, 1, 1, 0.3],
		[Blocks.CRYSTAL, 4, 10, 0.6], [Blocks.GLOW_LAMP, 2, 4, 0.6]],
}


# --- which sites a region holds ---------------------------------------------

static func region_of(v: Vector3i) -> Vector3i:
	return Vector3i(floori(v.x / float(REGION)), floori(v.y / float(REGION)),
		floori(v.z / float(REGION)))


## The sites in region `rk`, worked out from the seed. Deterministic: every
## machine, and every call, gets the same list.
static func derive_region(p: Planet, rk: Vector3i) -> Array:
	var out: Array = []
	if p.site_density.is_empty():
		return out
	var lo := Vector3(rk * REGION)
	var mid := lo + Vector3.ONE * (REGION * 0.5)
	# Only regions the surface actually passes through.
	var dm := p._norm(mid)
	if absf(dm - p.radius) > REGION * 0.9 + p.terrain_amp * 3.0:
		return out
	for kind in [WRECK, OUTPOST, RUIN, VAULT]:
		var dens: float = p.site_density.get(kind, 0.0)
		if dens <= 0.0 or p._hash01(rk, 4400 + kind) >= dens:
			continue
		var s := _make_site(p, rk, kind)
		if not s.is_empty():
			s["id"] = "%d:%d:%d:%d" % [kind, rk.x, rk.y, rk.z]
			out.append(s)
	return out


static func _make_site(p: Planet, rk: Vector3i, kind: int) -> Dictionary:
	var lo := Vector3(rk * REGION)
	var span := float(REGION - 2 * MARGIN)
	var pick := lo + Vector3(MARGIN, MARGIN, MARGIN) + Vector3(
		p._hash01(rk, 4500 + kind) * span, p._hash01(rk, 4510 + kind) * span,
		p._hash01(rk, 4520 + kind) * span)
	var dir := pick.normalized()
	var surf_pt := p._surface_point(dir)
	var upf := p._axis_of(dir) if p.shape_cube else p._axis_of(dir)
	var up := Vector3i(roundi(upf.x), roundi(upf.y), roundi(upf.z))
	# The topmost ground cell.
	var ground := Vector3i((surf_pt - Vector3(up) * 0.5).floor())
	var sites_seed := int(p._hash01(rk, 4600 + kind) * 2147483000.0)
	var rng := RandomNumberGenerator.new()
	rng.seed = sites_seed
	# A horizontal direction for the site's length, and its sideways partner.
	var perps := _perps(up)
	var u: Vector3i = perps[rng.randi() % 4]
	var v := Vector3i(up.y * u.z - up.z * u.y, up.z * u.x - up.x * u.z, up.x * u.y - up.y * u.x)
	var s := {"kind": kind, "up": up, "u": u, "v": v, "seed": sites_seed}
	var surf_d := p._surf(dir)
	# Nothing on the sea bed but a wreck, and nothing in a town.
	var wet := p.water_style != p.WATER_NONE and surf_d < p.water_level + 0.5
	if wet and kind != WRECK and kind != VAULT:
		return {}
	for st in p.settlements:
		if (Vector3(st["anchor"]) - surf_pt).length() < 90.0:
			return {}
	match kind:
		WRECK:
			s["L"] = rng.randi_range(14, 22)
			s["rw"] = rng.randi_range(2, 3)
			s["rh"] = rng.randi_range(2, 3)
			s["tilt"] = rng.randf_range(0.12, 0.3)
			s["sink"] = rng.randi_range(1, 2)
			s["gap"] = rng.randi_range(5, int(s["L"]) - 7) if rng.randf() < 0.5 else -99
			s["anchor"] = ground
		OUTPOST:
			s["A"] = rng.randi_range(7, 11)
			s["B"] = rng.randi_range(7, 9)
			s["anchor"] = ground
		RUIN:
			s["A"] = rng.randi_range(9, 13)
			s["B"] = rng.randi_range(9, 13)
			s["H"] = 5
			var depth := rng.randi_range(18, 32)
			s["anchor"] = ground - up * depth
			s["K"] = _shaft_length(p, s)
			if int(s["K"]) < 0:
				return {}
		VAULT:
			s["A"] = 7
			s["B"] = 7
			s["H"] = 4
			s["anchor"] = ground - up * rng.randi_range(38, 60)
	_set_bounds(s)
	# Stay inside the region, so nothing outside it ever needs to know.
	var rlo := rk * REGION
	var rhi := rlo + Vector3i.ONE * (REGION - 1)
	var blo: Vector3i = s["wlo"]
	var bhi: Vector3i = s["whi"]
	if blo.x < rlo.x or blo.y < rlo.y or blo.z < rlo.z \
			or bhi.x > rhi.x or bhi.y > rhi.y or bhi.z > rhi.z:
		return {}
	s["chests"] = _chest_cells(s)
	return s


## The four horizontal directions on a face whose up is `up`.
static func _perps(up: Vector3i) -> Array:
	var out: Array = []
	for d in [Vector3i(1, 0, 0), Vector3i(-1, 0, 0), Vector3i(0, 1, 0),
			Vector3i(0, -1, 0), Vector3i(0, 0, 1), Vector3i(0, 0, -1)]:
		if d != up and d != -up:
			out.append(d)
	return out


## How far a ruin's stairway has to climb to come out at the surface, from the
## doorway in its end wall. -1 if it never does within reach.
static func _shaft_length(p: Planet, s: Dictionary) -> int:
	var a0: int = int(s["A"]) - 1
	var bm: int = int(s["B"]) / 2
	for k in range(1, 48):
		var c := _to_world(s, a0 + k, k + 1, bm)
		var cv := Vector3(c) + Vector3(0.5, 0.5, 0.5)
		if p._norm(cv) >= p._surf(cv.normalized()) + 0.5:
			return k
	return -1


# --- local <-> world ----------------------------------------------------------

static func _to_world(s: Dictionary, a: int, h: int, b: int) -> Vector3i:
	return (s["anchor"] as Vector3i) + (s["u"] as Vector3i) * a \
		+ (s["up"] as Vector3i) * h + (s["v"] as Vector3i) * b


static func _dot(x: Vector3i, y: Vector3i) -> int:
	return x.x * y.x + x.y * y.y + x.z * y.z


## World-space box around a site, from the corners of its local one.
static func _set_bounds(s: Dictionary) -> void:
	var llo: Vector3i
	var lhi: Vector3i
	match int(s["kind"]):
		WRECK:
			var L: int = s["L"]
			var rh: int = s["rh"]
			var hc_hi := float(rh) - float(s["sink"])
			var hc_lo := hc_hi - float(L) * float(s["tilt"])
			llo = Vector3i(0, floori(hc_lo) - rh - 1, -int(s["rw"]) - 1)
			lhi = Vector3i(L - 1, ceili(hc_hi) + rh + 1, int(s["rw"]) + 1)
		OUTPOST:
			llo = Vector3i(0, -4, 0)
			lhi = Vector3i(int(s["A"]) - 1, 5, int(s["B"]) - 1)
		RUIN:
			var K: int = s["K"]
			var bm: int = int(s["B"]) / 2
			llo = Vector3i(0, -1, mini(0, bm - 2))
			lhi = Vector3i(int(s["A"]) + K + 1, maxi(int(s["H"]) + 1, K + 5), maxi(int(s["B"]) - 1, bm + 1))
		VAULT:
			llo = Vector3i(0, 0, 0)
			lhi = Vector3i(int(s["A"]) - 1, int(s["H"]) + 1, int(s["B"]) - 1)
	s["llo"] = llo
	s["lhi"] = lhi
	var wlo := Vector3i(1 << 30, 1 << 30, 1 << 30)
	var whi := -wlo
	for i in 8:
		var c := _to_world(s, llo.x if (i & 1) == 0 else lhi.x,
			llo.y if (i & 2) == 0 else lhi.y, llo.z if (i & 4) == 0 else lhi.z)
		wlo = Vector3i(mini(wlo.x, c.x), mini(wlo.y, c.y), mini(wlo.z, c.z))
		whi = Vector3i(maxi(whi.x, c.x), maxi(whi.y, c.y), maxi(whi.z, c.z))
	s["wlo"] = wlo
	s["whi"] = whi


# --- what a site is made of ---------------------------------------------------

## The block a site puts at `c`, or -1 where it leaves the world alone. AIR is
## a real answer: it is how a site carves its rooms out of rock.
static func block_at(p: Planet, s: Dictionary, c: Vector3i) -> int:
	var wlo: Vector3i = s["wlo"]
	var whi: Vector3i = s["whi"]
	if c.x < wlo.x or c.y < wlo.y or c.z < wlo.z or c.x > whi.x or c.y > whi.y or c.z > whi.z:
		return -1
	var d := c - (s["anchor"] as Vector3i)
	var a := _dot(d, s["u"])
	var h := _dot(d, s["up"])
	var b := _dot(d, s["v"])
	match int(s["kind"]):
		WRECK: return _wreck(p, s, c, a, h, b)
		OUTPOST: return _outpost(p, s, c, a, h, b)
		RUIN: return _ruin(p, s, c, a, h, b)
		VAULT: return _vault(s, a, h, b)
	return -1


## A ship that came down nose first: an elliptical hull along u, tilted, sunk
## into the ground at the nose, holed, sometimes broken in two.
static func _wreck(p: Planet, s: Dictionary, c: Vector3i, a: int, h: int, b: int) -> int:
	var L: int = s["L"]
	if a < 0 or a >= L:
		return -1
	var taper := 1.0 if a < L - 5 else float(L - a) / 5.0
	var ry := float(s["rh"]) * maxf(taper, 0.4)
	var rz := float(s["rw"]) * maxf(taper, 0.4)
	var hc := float(s["rh"]) - float(s["sink"]) - float(a) * float(s["tilt"])
	var dy := float(h) - hc
	var e := (float(b) / rz) ** 2 + (dy / ry) ** 2
	if e > 1.0:
		return -1
	var inner := ry > 1.2 and rz > 1.2 \
		and (float(b) / (rz - 1.0)) ** 2 + (dy / (ry - 1.0)) ** 2 < 1.0
	if inner:
		return Blocks.AIR
	# The shell. Torn open along the top, and sometimes right through.
	var gap: int = s["gap"]
	if dy > 0.0 and (a == gap or a == gap + 1):
		return Blocks.AIR
	if dy > 0.3 and p._hash01(c, 4700) < 0.14:
		return Blocks.AIR
	if a <= 1:
		return Blocks.THRUSTER
	if a >= L - 3 and dy > 0.0:
		return Blocks.GLASS
	return Blocks.METAL


## A small metal building, long abandoned: holes in the roof, gaps in the
## walls, a lamp still burning, on a plinth of the planet's own rock.
static func _outpost(p: Planet, s: Dictionary, c: Vector3i, a: int, h: int, b: int) -> int:
	var A: int = s["A"]
	var B: int = s["B"]
	if a < 0 or a >= A or b < 0 or b >= B or h < -4 or h > 5:
		return -1
	if h < 0:
		return p.pal_rock
	if h == 0:
		return Blocks.METAL
	if h == 5:
		return Blocks.AIR if p._hash01(c, 4710) < 0.35 else Blocks.METAL
	var edge := a == 0 or a == A - 1 or b == 0 or b == B - 1
	if edge:
		# A doorway in the front wall.
		if a == 0 and (b == B / 2 or b == B / 2 - 1) and h <= 2:
			return Blocks.AIR
		if h >= 3 and p._hash01(c, 4720) < 0.13:
			return Blocks.AIR
		if h == 2 and ((a + b) % 3) == 1:
			return Blocks.GLASS
		return Blocks.METAL
	if h == 1 and a == A - 2 and b == B - 2:
		return Blocks.GLOW_LAMP
	return Blocks.AIR


## A stone room under the ground, crystal at its corners, a stair up to an arch
## at the surface -- the arch is how anybody would know it is there.
static func _ruin(p: Planet, s: Dictionary, c: Vector3i, a: int, h: int, b: int) -> int:
	var A: int = s["A"]
	var B: int = s["B"]
	var H: int = s["H"]
	var K: int = s["K"]
	var bm := B / 2
	# The stairway: out of the end wall, climbing one block per block.
	if a >= A - 1 and a <= A - 1 + K + 1 and (b == bm or b == bm - 1):
		var k := a - (A - 1)
		if k == 0:
			if h >= 1 and h <= 3:
				return Blocks.AIR
		elif k <= K:
			if h == k:
				return Blocks.make_stair(Blocks.ROCK_STAIR, _facing_for(s["up"], s["u"]),
					Blocks.STAIR_STRAIGHT)
			if h > k and h <= k + 3:
				return Blocks.AIR
	# The arch over the top of the stair.
	var top := A - 1 + K
	if a == top and h >= K + 1 and h <= K + 4:
		if (b == bm - 2 or b == bm + 1) and h <= K + 3:
			return Blocks.ROCK
		if h == K + 4 and b >= bm - 2 and b <= bm + 1:
			return Blocks.ROCK
	if a < 0 or a >= A or b < 0 or b >= B or h < 0 or h > H + 1:
		return -1
	if h == 0:
		return Blocks.PLANK_DARK
	if h == H + 1:
		return Blocks.ROCK
	if a == 0 or a == A - 1 or b == 0 or b == B - 1:
		# Fallen in, here and there -- the rock behind shows through.
		if h >= 3 and p._hash01(c, 4730) < 0.2:
			return -1
		return Blocks.ROCK
	if (a == 1 or a == A - 2) and (b == 1 or b == B - 2):
		return Blocks.CRYSTAL
	if h == 1 and b == bm and (a == 2 or a == A - 3):
		return Blocks.TORCH
	return Blocks.AIR


## A sealed metal room deep underground, lit, with no way in but digging.
static func _vault(s: Dictionary, a: int, h: int, b: int) -> int:
	var A: int = s["A"]
	var B: int = s["B"]
	var H: int = s["H"]
	if a < 0 or a >= A or b < 0 or b >= B or h < 0 or h > H + 1:
		return -1
	if h == 0 or h == H + 1 or a == 0 or a == A - 1 or b == 0 or b == B - 1:
		return Blocks.METAL
	if h == 1 and (a == 1 or a == A - 2) and (b == 1 or b == B - 2):
		return Blocks.GLOW_LAMP
	return Blocks.AIR


## Which of a stair's four facings points along `dir` on a face whose up is
## `up` -- the same table Chunk.shape_boxes reads facings with.
static func _facing_for(up: Vector3i, dir: Vector3i) -> int:
	var ax := Vector3i(1, 0, 0)
	var bx := Vector3i(0, 0, 1)
	if absi(up.x) == 1:
		ax = Vector3i(0, 1, 0)
	elif absi(up.z) == 1:
		bx = Vector3i(0, 1, 0)
	var opts := [ax, bx, -ax, -bx]
	var i := opts.find(dir)
	return maxi(i, 0)


# --- chests -------------------------------------------------------------------

static func _chest_cells(s: Dictionary) -> Array:
	match int(s["kind"]):
		WRECK:
			var L: int = s["L"]
			var ac := int(L * 0.45)
			var ry := float(s["rh"])
			var hc := float(s["rh"]) - float(s["sink"]) - float(ac) * float(s["tilt"])
			var hi := floori(hc - (ry - 1.0)) + 1
			return [_to_world(s, ac, hi, 0)]
		OUTPOST:
			return [_to_world(s, int(s["A"]) - 2, 1, 1)]
		RUIN:
			return [_to_world(s, int(s["A"]) / 2, 1, int(s["B"]) - 2)]
		VAULT:
			return [_to_world(s, 3, 1, 2), _to_world(s, 3, 1, 4)]
	return []


## Put what a site holds into a chest. Seeded by the site, so the same site
## always held the same things.
static func fill(p: Planet, s: Dictionary, st: Station, which: int) -> void:
	var rng := RandomNumberGenerator.new()
	rng.seed = int(s["seed"]) + which * 977
	var kind := int(s["kind"])
	for row in LOOT.get(kind, []):
		if rng.randf() < float(row[3]):
			st.store_add(int(row[0]), rng.randi_range(int(row[1]), int(row[2])))
	# This world's own ores: ruins remember what the place was mined for, and a
	# vault keeps the best of it.
	if (kind == RUIN or kind == VAULT) and not p.ore_defs.is_empty():
		var picks := 1 if kind == RUIN else 2
		for i in picks:
			var od: Dictionary = p.ore_defs[rng.randi() % p.ore_defs.size()]
			if kind == VAULT:
				for o in p.ore_defs:
					if int(o["tier"]) > int(od["tier"]) and rng.randf() < 0.6:
						od = o
			st.store_add(int(od["block"]), rng.randi_range(2, 6) if kind == RUIN else rng.randi_range(4, 10),
				od["props"], p.planet_name,
				{"name": od["name"], "color": od["color"], "tier": od["tier"]})
