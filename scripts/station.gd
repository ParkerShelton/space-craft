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


static func capacity_of(k: int) -> int:
	if k == Blocks.GENERATOR:
		return 6   # a fuel bunker: feed it ore and let it run
	if k == Blocks.CHEST:
		return CHEST_SLOTS
	if k == Blocks.POWER_BAY:
		return 4   # a rack of batteries
	if k == Blocks.OXYGEN_PLANT or k == Blocks.HEATER or k == Blocks.COOLER:
		return 2   # spare filters / elements: no recipes, just somewhere to stash parts
	if k == Blocks.FORGE:
		return 16  # a multiblock-built upgrade over the hand-built Smelter
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
	var box := BoxMesh.new()
	box.size = Vector3(0.96, 0.96, 0.96)
	_mi.mesh = box
	# the station's ORIGIN is the cell center (set on spawn), so the mesh/collision
	# sit at local zero -- this keeps it centered regardless of the orientation basis
	_mi.position = Vector3.ZERO
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
	_col.position = Vector3.ZERO


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
			if s["count"] <= 0:
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
func start_craft(craft: Dictionary) -> int:
	if _job != "":
		return -1
	if craft.has("reqs"):
		if not _afford_reqs(craft["reqs"]):
			return 0
		_job = "craft"
		_job_craft = craft
		_job_t = 0.0
		_job_total = 0.6
		return 1
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
	_job_t = 0.0
	_job_total = maxf(0.4, cost * CRAFT_TIME_PER)
	return 1


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


const BATTERY_CAP := 400.0   # power one Battery holds
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
		var cap: float = BATTERY_CAP * float(int(slot.get("count", 0)))
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
		return


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
		_do_craft(_job_craft)
	_job = ""
	_job_t = 0.0
	_job_total = 0.0
	_job_craft = {}


# Consume either a plain `reqs` list or the primary material (+ optional `extra`
# resource) and output the crafted item into storage. Gear/ship-part outputs
# carry the source material's identity + a derived stat; plain outputs (Alloy,
# Circuitry, Hull Plate, Door, Glass) don't need one.
func _do_craft(craft: Dictionary) -> void:
	if craft.has("reqs"):
		_consume_reqs(craft["reqs"])
		store_add(int(craft["out"]), int(craft.get("n", 1)))
		return
	var mtype := Blocks.primary_material_for(kind)
	var m = null
	for s in storage:
		if s["count"] > 0 and Blocks.id_matches_material(s["id"], mtype):
			m = s
			break
	if m == null:
		return
	var cost := int(craft["cost"])
	if m["count"] < cost:
		return
	if craft.has("extra") and _count_req(craft["extra"]) < int(craft["extra"]["n"]):
		return
	var props: Dictionary = m["props"]
	var src: String = m.get("src", "")
	var mname: String = m["mat"].get("name", "")
	var mcolor: Color = m["mat"].get("color", Color(0.8, 0.8, 0.8))
	var mtier: int = m["mat"].get("tier", 0)
	m["count"] -= cost
	if m["count"] <= 0:
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
	store_add(out, int(craft.get("n", 1)), props, src, cmat)
