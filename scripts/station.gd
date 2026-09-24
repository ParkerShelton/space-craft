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

# --- timed jobs (refining/crafting isn't instant) ---
const REFINE_TIME_PER := 0.4      # seconds per unit of ore
const CRAFT_TIME_PER := 0.4       # seconds per unit of material consumed
var _job := ""                    # "" / "refine" / "craft"
var _job_t := 0.0
var _job_total := 0.0
var _job_craft := {}
var _job_times := 1              # how many of _job_craft this job makes

var _mi: MeshInstance3D
var _col: CollisionShape3D

# --- built machines ----------------------------------------------------------
# A machine assembled from blocks reuses this class for its storage, jobs and
# UI, but must NOT put a body inside the structure the player built -- the
# blocks are the machine. Headless stations skip the mesh and collision and are
# reached by right-clicking their Machine Core instead of by looking at them.
var headless := false
## Set from the machine registry: false while the structure is missing a block.
var active := true

# --- power ---
const POWER_MAX := 1000.0
var power := 0.0
var burn_t := 0.0          # seconds left on the current unit of fuel
var burn_rate := 0.0       # power/sec it is producing while that burns

# Base machines. Both are driven by Planet.update_base, which owns the sealed
# room they serve -- a Life Support with no room around it has nothing to fill.
const O2_POWER_RATE := 4.0    # power/sec to keep scrubbing
const HEAT_POWER_RATE := 6.0  # power/sec to hold a room at 20 C (heater OR cooler)
var o2 := 0.0                 # 0..1 breathable air in this machine's room
var warmth := 15.0            # degrees C it is holding its room at
## What the cradle's model is currently showing: x = is a battery seated, y =
## how full its gauge is drawn. The model is rebuilt only when this would
## visibly change, so a bay draining over minutes remeshes a few dozen times
## rather than sixty times a second.
var _bay_shown := Vector2(-1, -1)


static func capacity_of(k: int) -> int:
	if k == Blocks.GENERATOR:
		return 6   # a fuel bunker: feed it ore and let it run
	if k == Blocks.CHEST:
		return CHEST_SLOTS
	if k == Blocks.POWER_BAY:
		return 1   # one battery, seated in the cradle -- no inventory to open
	if k == Blocks.OXYGEN_PLANT or k == Blocks.HEATER or k == Blocks.COOLER:
		return 2   # spare filters / elements: no recipes, just somewhere to stash parts
	if k == Blocks.FORGE:
		return 16  # a multiblock-built upgrade over the hand-built Smelter
	if k == Blocks.BED:
		return 0   # you sleep in it; there is nowhere to put anything
	if k == Blocks.SHAPER:
		# One INPUT slot -- you feed it a single block and pick a shape -- plus
		# one for the result to land in. A literal single slot leaves the
		# crafted shapes nowhere to go once the input is sitting in it.
		return 2
	return STORAGE_SLOTS


func capacity() -> int:
	return capacity_of(kind)


func _init() -> void:
	_ensure_storage()


# (Re)size storage to this station's capacity, preserving existing slots.
func _ensure_storage() -> void:
	var cap := capacity()
	while storage.size() < cap:
		storage.append({"id": Blocks.AIR, "count": 0, "eighths": 0, "props": {},
			"src": "", "mat": {}})
	# Never shrink past something that is IN there. A station can now change kind
	# under your feet -- a Forge whose metal you mined drops back to a Smelter --
	# and a smaller capacity must not be a way to delete what you had stored.
	if storage.size() > cap:
		var keep := cap
		for i in range(storage.size() - 1, cap - 1, -1):
			var sl: Dictionary = storage[i]
			if int(sl.get("count", 0)) > 0 or int(sl.get("eighths", 0)) > 0:
				keep = i + 1
				break
		storage.resize(keep)


func configure(k: int, w: WorldManager) -> void:
	kind = k
	world = w
	_ensure_storage()
	if not headless:
		_build_visual()


## How far through being taken apart this station is, 0 to 1. Shown rather than
## merely counted: it shrinks a little and darkens toward its own break, so a
## station comes apart in front of you instead of vanishing on a timer.
func set_dismantle(t: float) -> void:
	var k := clampf(t, 0.0, 1.0)
	if _mi == null:
		return
	_mi.scale = Vector3.ONE * (1.0 - 0.12 * k)
	var mat := _mi.get_active_material(0)
	if mat is StandardMaterial3D:
		(mat as StandardMaterial3D).albedo_color = Color(1, 1, 1).lerp(Color(1.0, 0.55, 0.4), k)


func title() -> String:
	return Blocks.name_of(kind)


func _ready() -> void:
	if _mi == null and not headless:
		_build_visual()


func _build_visual() -> void:
	if _mi == null:
		_mi = MeshInstance3D.new()
		add_child(_mi)
	if _col == null:
		_col = CollisionShape3D.new()
		add_child(_col)
	# The station's own model, standing on the ground its footprint covers.
	var fp := StationModels.footprint(kind)
	if kind == Blocks.POWER_BAY:
		_bay_shown = _bay_state()
		_mi.mesh = StationModels.power_bay_mesh(_bay_shown.x > 0.5, _bay_shown.y)
	else:
		_mi.mesh = StationModels.mesh_for(kind)
	# The station's ORIGIN is the centre of the cell it was put down in, so the
	# model hangs half a block below it to stand on that cell's floor, and a
	# tall station's box reaches up from there.
	_mi.position = Vector3(0, -0.5, 0)
	_mi.material_override = null   # the model carries its own material
	var shape := BoxShape3D.new()
	shape.size = Vector3(fp)
	_col.shape = shape
	_col.position = Vector3(0, (float(fp.y) - 1.0) * 0.5, 0)


# --- storage helpers ----------------------------------------------------------

## Add items to internal storage; returns leftover that didn't fit.
func store_add(id: int, n: int, props: Dictionary = {}, src: String = "", mat: Dictionary = {}) -> int:
	if id == Blocks.AIR or n <= 0:
		return n
	# Things that wear out are one to a slot, each with its own wear.
	if Blocks.max_durability(id) > 0:
		while n > 0:
			var put := false
			for s in storage:
				if int(s.get("count", 0)) == 0 and int(s.get("eighths", 0)) == 0:
					s["id"] = id
					s["count"] = 1
					s["eighths"] = 0
					s["props"] = props
					s["src"] = src
					s["mat"] = mat
					s.erase("dur")
					put = true
					break
			if not put:
				return n
			n -= 1
		return 0
	for s in storage:
		if s["count"] > 0 and s["id"] == id and s.get("src", "") == src:
			s["count"] += n
			return 0
	for s in storage:
		# A slot holding nothing but change is not a free slot. Treating it as
		# one overwrote the fraction that was in it.
		if int(s.get("count", 0)) == 0 and int(s.get("eighths", 0)) == 0:
			s["id"] = id
			s["count"] = n
			s["eighths"] = 0
			s["props"] = props
			s["src"] = src
			s["mat"] = mat
			return 0
	return n  # full


## Plain multi-requirement crafts (Carpenter's structural blocks, Shipworks' Hull
## Plate) are checked/consumed against THIS station's own storage, mirroring the
## hand-recipe reqs format ({id,n} or {any:[ids],n}) but never touching the
## player's inventory directly -- everything a station builds comes from what's
## loaded into it.
func _count_req(req: Dictionary) -> int:
	var total := 0
	for s in storage:
		if s["count"] <= 0:
			continue
		if req.has("id") and s["id"] == int(req["id"]):
			total += s["count"]
		elif req.has("any") and s["id"] in req["any"]:
			total += s["count"]
	return total


## The props of the stuff a craft is really made OF, for the crafts whose yield
## depends on it: the refined material in the hopper if there is one, otherwise
## whatever in there carries a material at all.
func _yield_props() -> Dictionary:
	for s in storage:
		if int(s.get("count", 0)) > 0 and Blocks.is_refined(int(s["id"])):
			return s.get("props", {})
	for s2 in storage:
		if int(s2.get("count", 0)) > 0 				and not (s2.get("props", {}) as Dictionary).is_empty():
			return s2.get("props", {})
	return {}


func _afford_reqs(reqs: Array) -> bool:
	for r in reqs:
		if _count_req(r) < int(r["n"]):
			return false
	return true


func _consume_reqs(reqs: Array) -> void:
	for r in reqs:
		var need := int(r["n"])
		for s in storage:
			if need <= 0:
				break
			if s["count"] <= 0:
				continue
			var matches: bool = (r.has("id") and s["id"] == int(r["id"])) \
				or (r.has("any") and s["id"] in r["any"])
			if not matches:
				continue
			var take: int = mini(need, s["count"])
			s["count"] -= take
			need -= take
			# Not while eighths are left: the id is what those are OF.
			if s["count"] <= 0 and int(s.get("eighths", 0)) <= 0:
				s["id"] = Blocks.AIR
				s["props"] = {}
				s["src"] = ""
				s["mat"] = {}


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


# --- timed jobs ---------------------------------------------------------------

func busy() -> bool:
	return _job != ""


func job_progress() -> float:
	return clampf(_job_t / _job_total, 0.0, 1.0) if _job_total > 0.0 else 0.0


func job_text() -> String:
	if _job == "":
		return ""
	var pct := int(job_progress() * 100.0)
	return ("Refining… %d%%" % pct) if _job == "refine" else ("Crafting… %d%%" % pct)


# Start smelting all loaded ore. Returns unit count (>0), 0 if no ore, -1 if busy.
func start_refine() -> int:
	if _job != "":
		return -1
	var n := 0
	for s in storage:
		if s["count"] > 0 and Blocks.is_ore(s["id"]):
			n += s["count"]
	if n == 0:
		return 0
	_job = "refine"
	_job_t = 0.0
	var per := REFINE_TIME_PER * (0.5 if kind == Blocks.FORGE else 1.0)  # a Forge runs hot
	_job_total = maxf(0.4, n * per)
	return n


# Start a craft. Returns 1 (started), 0 (not enough material), -1 (busy).
## `times` is how many to make; 0 or less means as many as what is loaded
## allows. They are made as ONE job, a little longer than a single one rather
## than that many single ones end to end -- sawing twenty planks should not be
## twelve seconds of watching a bar. Returns how many will be made, 0 if not
## even one can be, -1 if busy.
func start_craft(craft: Dictionary, times: int = 1) -> int:
	if _job != "":
		return -1
	if craft.has("reqs"):
		var most := _affordable(craft["reqs"])
		if most <= 0:
			return 0
		var k := most if times <= 0 else mini(times, most)
		_job = "craft"
		_job_craft = craft
		_job_times = k
		_job_t = 0.0
		_job_total = minf(0.6 + 0.12 * float(k - 1), 4.0)
		return k
	var mtype := Blocks.primary_material_for(kind)
	var cost := int(craft["cost"])
	var has_primary := false
	for s in storage:
		if s["count"] >= cost and Blocks.id_matches_material(s["id"], mtype):
			has_primary = true
			break
	if not has_primary:
		return 0
	if craft.has("extra") and _count_req(craft["extra"]) < int(craft["extra"]["n"]):
		return 0
	_job = "craft"
	_job_craft = craft
	# Made one after another at the end, each only if it can still be paid
	# for, so "all" simply stops when the material runs out.
	_job_times = 999 if times <= 0 else times
	_job_t = 0.0
	_job_total = maxf(0.4, cost * CRAFT_TIME_PER)
	return 1 if times == 1 else _job_times


## How many times over `reqs` can be paid from what is loaded.
func _affordable(reqs: Array) -> int:
	var most := 1 << 30
	for r in reqs:
		var need := int(r["n"])
		if need <= 0:
			continue
		most = mini(most, _count_req(r) / need)
	return 0 if most == 1 << 30 else most


## Burns ore for power. Duration and output both scale with the ore's
## Combustion, so which ore you shovel in genuinely matters -- and a damaged
## structure produces nothing until its missing block is replaced.
func _tick_generator(delta: float) -> void:
	if kind != Blocks.GENERATOR:
		return
	if not active:
		burn_t = 0.0
		burn_rate = 0.0
		return
	if burn_t > 0.0:
		burn_t -= delta
		power = minf(power + burn_rate * delta, POWER_MAX)
		if burn_t > 0.0:
			return
		burn_rate = 0.0
	if power >= POWER_MAX:
		return   # full: don't waste fuel
	for s in storage:
		if int(s.get("count", 0)) <= 0:
			continue
		var props: Dictionary = s.get("props", {})
		if not Blocks.is_fuel(int(s["id"]), props):
			continue
		s["count"] = int(s["count"]) - 1
		if int(s["count"]) <= 0:
			s["id"] = Blocks.AIR
			s["props"] = {}
			s["src"] = ""
			s["mat"] = {}
		burn_t = Blocks.fuel_burn_time(props)
		burn_rate = Blocks.fuel_power_rate(props)
		return


## What a battery holds if nothing says otherwise. A real one asks its own
## material -- see Blocks.battery_capacity -- because how much charge a cell
## takes is a question about what it is made of.
const BATTERY_CAP := 400.0
const CHARGE_RATE := 45.0    # power/sec a Generator pushes into batteries in it
const BAY_RATE := 90.0       # power/sec a Power Bay pulls out of them
const SHIP_POWER := 900.0    # power to fill a ship's charge tank from empty
const SHIP_AIR_POWER := 700.0  # power to fill its air tank from empty


## Batteries sitting in a Generator soak up its output. This is the only way to
## get power off a planet, so it is deliberately the simplest possible action:
## drop them in and wait.
func _tick_batteries(delta: float) -> void:
	if kind != Blocks.GENERATOR or power <= 0.0:
		return
	for slot in storage:
		if int(slot.get("id", Blocks.AIR)) != Blocks.BATTERY:
			continue
		var cap: float = Blocks.battery_capacity(slot.get("props", {})) 			* float(int(slot.get("count", 0)))
		var held: float = float((slot["props"] as Dictionary).get("charge", 0.0))
		if held >= cap:
			continue
		var moved: float = minf(minf(CHARGE_RATE * delta, cap - held), power)
		(slot["props"] as Dictionary)["charge"] = held + moved
		power -= moved
		return   # one battery at a time, so a stack fills in order


## A Power Bay empties batteries into the ship it is mounted on. Charge first --
## without power the scrubbers stop and the air goes much faster.
func _tick_power_bay(delta: float) -> void:
	if kind != Blocks.POWER_BAY:
		return
	var sh := get_parent() as Ship
	if sh == null or (sh.charge >= 1.0 and sh.air >= 1.0):
		return
	for slot in storage:
		if int(slot.get("id", Blocks.AIR)) != Blocks.BATTERY:
			continue
		var held: float = float((slot["props"] as Dictionary).get("charge", 0.0))
		if held <= 0.0:
			continue
		var moved: float = minf(BAY_RATE * delta, held)
		(slot["props"] as Dictionary)["charge"] = held - moved
		if sh.charge < 1.0:
			sh.charge = minf(sh.charge + moved / SHIP_POWER, 1.0)
		else:
			sh.air = minf(sh.air + moved / SHIP_AIR_POWER, 1.0)
		_refresh_bay()
		return


## What the cradle SHOULD be showing: whether a battery is seated, and its
## charge rounded to the nearest step the gauge can actually draw.
func _bay_state() -> Vector2:
	var slot: Dictionary = storage[0] if storage.size() > 0 else {}
	if int(slot.get("id", Blocks.AIR)) != Blocks.BATTERY:
		return Vector2(0, 0)
	var held: float = float((slot.get("props", {}) as Dictionary).get("charge", 0.0))
	var f: float = clampf(held / Blocks.battery_capacity(slot.get("props", {})), 0.0, 1.0)
	return Vector2(1, snappedf(f, 0.04))


## Keep the cradle looking like what is in it.
func _refresh_bay() -> void:
	if kind != Blocks.POWER_BAY or headless or _mi == null:
		return
	var want := _bay_state()
	if want.is_equal_approx(_bay_shown):
		return
	_bay_shown = want
	_mi.mesh = StationModels.power_bay_mesh(want.x > 0.5, want.y)


## Put `slot` in the cradle and hand back whatever was in it -- the swap that
## right-clicking a bay with a battery in hand performs. Either side may be
## empty, so this covers taking one out and putting one in as well.
## Is there a battery seated in this cradle?
func bay_has_battery() -> bool:
	if storage.is_empty():
		return false
	return int(storage[0].get("id", Blocks.AIR)) == Blocks.BATTERY 		and int(storage[0].get("count", 0)) > 0


func bay_swap(incoming: Dictionary) -> Dictionary:
	if storage.is_empty():
		_ensure_storage()
	var was: Dictionary = storage[0].duplicate(true)
	storage[0] = incoming.duplicate(true)
	_refresh_bay()
	if int(was.get("id", Blocks.AIR)) == Blocks.AIR or int(was.get("count", 0)) <= 0:
		return {}
	return was


func _process(delta: float) -> void:
	_tick_generator(delta)
	_tick_batteries(delta)
	_tick_power_bay(delta)
	if _job == "":
		return
	_job_t += delta
	if _job_t < _job_total:
		return
	if _job == "refine":
		refine_all()
	elif _job == "craft":
		for i in _job_times:
			if not _do_craft(_job_craft):
				break
	_job_times = 1
	_job = ""
	_job_t = 0.0
	_job_total = 0.0
	_job_craft = {}


# Consume either a plain `reqs` list or the primary material (+ optional `extra`
# resource) and output the crafted item into storage. Gear/ship-part outputs
# carry the source material's identity + a derived stat; plain outputs (Alloy,
# Circuitry, Hull Plate, Door, Glass) don't need one.
## Returns whether one was made -- false once the material has run out.
func _do_craft(craft: Dictionary) -> bool:
	if craft.has("reqs"):
		if not _afford_reqs(craft["reqs"]):
			return false
		# Read the material BEFORE consuming it: a yield that depends on what a
		# thing is made of has to look at the stuff while it is still there.
		var mprops: Dictionary = _yield_props()
		_consume_reqs(craft["reqs"])
		var many := int(craft.get("n", 1))
		if bool(craft.get("yield_from_material", false)):
			many = Blocks.yield_for(int(craft["out"]), mprops, many)
		store_add(int(craft["out"]), many, mprops)
		return true
	var mtype := Blocks.primary_material_for(kind)
	var m = null
	for s in storage:
		if s["count"] > 0 and Blocks.id_matches_material(s["id"], mtype):
			m = s
			break
	if m == null:
		return false
	var cost := int(craft["cost"])
	if m["count"] < cost:
		return false
	if craft.has("extra") and _count_req(craft["extra"]) < int(craft["extra"]["n"]):
		return false
	var props: Dictionary = m["props"]
	var src: String = m.get("src", "")
	var mname: String = m["mat"].get("name", "")
	var mcolor: Color = m["mat"].get("color", Color(0.8, 0.8, 0.8))
	var mtier: int = m["mat"].get("tier", 0)
	m["count"] -= cost
	if m["count"] <= 0 and int(m.get("eighths", 0)) <= 0:
		m["id"] = Blocks.AIR
		m["props"] = {}
		m["src"] = ""
		m["mat"] = {}
	if craft.has("extra"):
		_consume_reqs([craft["extra"]])
	var out := int(craft["out"])
	var cmat := {"name": mname, "color": mcolor, "tier": mtier}
	match out:
		Blocks.DRILL:
			cmat["power"] = Blocks.drill_power(props)
		Blocks.SUIT:
			cmat["resist"] = Blocks.suit_resist(props)
		Blocks.WEAPON:
			cmat["damage"] = Blocks.weapon_damage(props)
		Blocks.PULSE_PISTOL:
			cmat["damage"] = Blocks.ranged_weapon_damage(props)
	var count := int(craft.get("n", 1))
	if bool(craft.get("yield_from_material", false)):
		count = Blocks.yield_for(out, props, count)
	store_add(out, count, props, src, cmat)
	return true
