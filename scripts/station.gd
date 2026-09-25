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
## The switch on the front of a generator. `active` is whether the machine is
## WHOLE -- a hole knocked in it stops it -- and this is whether you have asked
## it to run, which is a different question and wants a different answer.
var switched_on := true

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
## The same, for a generator: battery seated, its charge, burning, power level.
var _gen_shown := Color(-1, -1, -1, -1)
var _lever: MeshInstance3D
var _lever_t := 0.0
## A chest's lid, and how far open it is (0 shut, 1 wide). Set lid_open and it
## swings; nothing else has to be told.
var _lid: MeshInstance3D
var lid_open := false
var _lid_t := 0.0


static func capacity_of(k: int) -> int:
	if k == Blocks.GENERATOR:
		# Two bays with a job each, not a bunker: slot 0 is the battery cradle
		# on top, slot 1 is the fuel hopper beside it. Both are on the outside
		# of the model where you can see what is in them.
		return 2
	if k == Blocks.CHEST:
		return CHEST_SLOTS
	if k == Blocks.POWER_BAY:
		return 1   # one battery, seated in the cradle -- no inventory to open
	if k == Blocks.ANVIL:
		return 2   # the workpiece on its face, and the pile waiting beside it
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
	if kind == Blocks.CHEST:
		# The lid is a node of its own, hinged at the back, so it can actually
		# swing rather than be drawn in two states.
		_mi.mesh = StationModels.mesh_from_boxes(StationModels.chest_body_boxes())
		if _lid == null:
			_lid = MeshInstance3D.new()
			_lid.mesh = StationModels.mesh_from_boxes(
				StationModels.chest_lid_boxes(StationModels.CHEST_HINGE))
			_lid.position = StationModels.CHEST_HINGE + Vector3(0, -0.5, 0)
			add_child(_lid)
	elif kind == Blocks.POWER_BAY:
		_bay_shown = _bay_state()
		_mi.mesh = StationModels.power_bay_mesh(_bay_shown.x > 0.5, _bay_shown.y)
	elif kind == Blocks.ANVIL:
		_anvil_shown = "-"
		_mi.mesh = StationModels.anvil_mesh("", Color.WHITE)
		_refresh_anvil.call_deferred()
	elif kind == Blocks.GENERATOR:
		_gen_shown = gen_state()
		_mi.mesh = StationModels.generator_mesh(_gen_shown.r > 0.5, _gen_shown.g,
			_gen_shown.b > 0.5, _gen_shown.a)
		if _lever == null:
			# A node of its own, hinged where it meets the case, so throwing it
			# is a thing that happens rather than two pictures.
			_lever = MeshInstance3D.new()
			_lever.mesh = StationModels.mesh_from_boxes(
				StationModels.generator_lever_boxes())
			_lever.position = StationModels.GEN_LEVER + Vector3(0, -0.5, 0)
			_lever_t = 1.0 if switched_on else 0.0
			_lever.rotation.x = lever_angle(_lever_t)
			add_child(_lever)
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
		elif req.has("refined") and Blocks.is_refined(int(s["id"])):
			# "refined: true" means any refined material will do. It was not
			# understood here at all, so it counted as nothing you had -- which
			# quietly made every Fabricator recipe asking for refined stock (Wire,
			# Machine Core, Battery) impossible to make at the bench.
			total += s["count"]
	return total


## The props of the stuff a craft is really made OF, for the crafts whose yield
## depends on it: the refined material in the hopper if there is one, otherwise
## whatever in there carries a material at all.
func _yield_props(reqs: Array = []) -> Dictionary:
	# What the recipe itself asks for comes first: Wire is made from a bar, and
	# a bar's worth of wire is a question about THAT bar's ore, not about an
	# ingot that happens to be sitting in the next slot.
	for r in reqs:
		var rd: Dictionary = r
		for s0 in storage:
			if int(s0.get("count", 0)) <= 0 or (s0.get("props", {}) as Dictionary).is_empty():
				continue
			var sid := int(s0["id"])
			if (rd.has("id") and sid == int(rd["id"])) \
					or (rd.has("refined") and Blocks.is_refined(sid)):
				return s0.get("props", {})
	for s in storage:
		if int(s.get("count", 0)) > 0 and Blocks.is_refined(int(s["id"])):
			return s.get("props", {})
	for s2 in storage:
		if int(s2.get("count", 0)) > 0 				and not (s2.get("props", {}) as Dictionary).is_empty():
			return s2.get("props", {})
	return {}


## Could this craft be started right now? The same tests start_craft makes,
## without starting anything -- so the panel can show what is possible before
## you click it.
func can_make(craft: Dictionary) -> bool:
	if craft.has("reqs"):
		return _afford_reqs(craft["reqs"])
	var mtype := Blocks.primary_material_for(kind)
	var cost := int(craft.get("cost", 1))
	var has_primary := false
	for s in storage:
		if s["count"] >= cost and Blocks.id_matches_material(s["id"], mtype):
			has_primary = true
			break
	if not has_primary:
		return false
	if craft.has("extra") and _count_req(craft["extra"]) < int(craft["extra"]["n"]):
		return false
	return true


## How much of what a requirement asks for is loaded, so the panel can say
## "3 of 12" rather than only whether the whole recipe is possible.
func req_have(req: Dictionary) -> int:
	return _count_req(req)


## How much of this station's primary material is loaded, for the crafts paid
## in it rather than in a list of requirements.
func primary_have() -> int:
	var mtype := Blocks.primary_material_for(kind)
	var total := 0
	for s in storage:
		if s["count"] > 0 and Blocks.id_matches_material(s["id"], mtype):
			total += int(s["count"])
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
				or (r.has("any") and s["id"] in r["any"]) \
				or (r.has("refined") and Blocks.is_refined(int(s["id"])))
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
		elif s["count"] > 0 and int(s["id"]) == Blocks.SCRAP:
			# Remelted: back into the very ingot it was beaten from.
			var back := scrap_to_ingot(s)
			s["id"] = back["id"]
			s["src"] = back["src"]
			s["mat"] = back["mat"]
			done += 1
	return done


## An ingot's worth of anything beaten from one (bar, sheet, scrap) turned back
## into that ingot: its id, source and material as they were.
static func scrap_to_ingot(s: Dictionary) -> Dictionary:
	var mat: Dictionary = (s.get("mat", {}) as Dictionary).duplicate()
	var id := int(mat.get("ingot", Blocks.REFINED_0))
	var src := str(mat.get("src0", s.get("src", "")))
	mat.erase("ingot")
	mat.erase("src0")
	return {"id": id, "src": src, "mat": mat}


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
		if s["count"] > 0 and (Blocks.is_ore(s["id"]) or int(s["id"]) == Blocks.SCRAP):
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
	if not active or not switched_on:
		# Thrown off mid-burn, what is in the firebox stays in it. Coming back
		# to a generator you switched off and finding its fuel gone would be a
		# punishment for tidiness.
		return
	if burn_t > 0.0:
		burn_t -= delta
		power = minf(power + burn_rate * delta, POWER_MAX)
		if burn_t > 0.0:
			return
		burn_rate = 0.0
	if power >= POWER_MAX:
		return   # full: don't waste fuel
	# Only the hopper burns. The cradle is not a place to keep ore, and any
	# old slots left over from the six-slot bunker are just holding things.
	var s: Dictionary = gen_fuel()
	if int(s.get("count", 0)) <= 0:
		return
	var props: Dictionary = s.get("props", {})
	if not Blocks.is_fuel(int(s["id"]), props):
		return
	s["count"] = int(s["count"]) - 1
	if int(s["count"]) <= 0:
		s["id"] = Blocks.AIR
		s["props"] = {}
		s["src"] = ""
		s["mat"] = {}
	burn_t = Blocks.fuel_burn_time(props)
	burn_rate = Blocks.fuel_power_rate(props)


## What a battery holds if nothing says otherwise. A real one asks its own
## material -- see Blocks.battery_capacity -- because how much charge a cell
## takes is a question about what it is made of.
const BATTERY_CAP := 400.0
const CHARGE_RATE := 45.0    # power/sec a Generator pushes into batteries in it
const BAY_RATE := 90.0       # power/sec a Power Bay pulls out of them
const SHIP_POWER := 900.0    # power to fill a ship's charge tank from empty
const SHIP_AIR_POWER := 700.0  # power to fill its air tank from empty


## The generator's two bays by name, so nothing has to remember which index is
## which. Slot 0 is the cradle, slot 1 is the hopper.
func gen_battery() -> Dictionary:
	return storage[0] if storage.size() > 0 else {}


func gen_fuel() -> Dictionary:
	return storage[1] if storage.size() > 1 else {}


func gen_has_battery() -> bool:
	var s0 := gen_battery()
	return int(s0.get("id", Blocks.AIR)) == Blocks.BATTERY and int(s0.get("count", 0)) > 0


## What the model is currently showing: battery seated, its charge, burning,
## how full the machine's own store is.
func gen_state() -> Color:
	var seated := gen_has_battery()
	var f := 0.0
	if seated:
		var props: Dictionary = gen_battery().get("props", {})
		f = clampf(float(props.get("charge", 0.0)) / Blocks.battery_capacity(props),
			0.0, 1.0)
	return Color(1.0 if seated else 0.0, snappedf(f, 0.04),
		1.0 if burn_t > 0.0 else 0.0, snappedf(power / POWER_MAX, 0.04))


## Keep the model looking like what is in it and what it is doing.
func _refresh_gen() -> void:
	if kind != Blocks.GENERATOR or headless or _mi == null:
		return
	var want := gen_state()
	if want.is_equal_approx(_gen_shown):
		return
	_gen_shown = want
	_mi.mesh = StationModels.generator_mesh(want.r > 0.5, want.g, want.b > 0.5, want.a)


## Swap what is in the cradle for what you are holding. Either side may be
## empty, so this is taking one out and putting one in as well.
func gen_swap_battery(incoming: Dictionary) -> Dictionary:
	_ensure_storage()
	var was: Dictionary = storage[0].duplicate(true)
	storage[0] = incoming.duplicate(true)
	_refresh_gen()
	if int(was.get("id", Blocks.AIR)) == Blocks.AIR or int(was.get("count", 0)) <= 0:
		return {}
	return was


## The same for the hopper.
func gen_swap_fuel(incoming: Dictionary) -> Dictionary:
	_ensure_storage()
	var was: Dictionary = storage[1].duplicate(true)
	storage[1] = incoming.duplicate(true)
	_refresh_gen()
	if int(was.get("id", Blocks.AIR)) == Blocks.AIR or int(was.get("count", 0)) <= 0:
		return {}
	return was


## Throw the switch. Returns what it is now.
func gen_toggle() -> bool:
	switched_on = not switched_on
	return switched_on


# --- the anvil -------------------------------------------------------------------
#
# One workpiece, in storage[0], with how many times it has been struck kept on
# it as "hits" -- so a half-beaten piece is saved with the world like anything
# else. What it IS at any moment is Blocks.smith_shape of those hits.
#
# storage[1] is the PILE: more of the same, set down beside the anvil, so a
# stack of ingots can be worked one after another. Taking a finished piece off
# the face slides the next one on (see anvil_feed).

var _anvil_shown := "-"


func anvil_piece() -> Dictionary:
	if storage.is_empty() or int(storage[0].get("count", 0)) <= 0:
		return {}
	return storage[0]


func anvil_shape() -> String:
	var p := anvil_piece()
	if p.is_empty():
		return ""
	return Blocks.smith_shape(int(p.get("hits", 0)), p.get("props", {}))


func anvil_colour() -> Color:
	var p := anvil_piece()
	var mat: Dictionary = p.get("mat", {})
	return mat.get("color", Color(0.7, 0.68, 0.64))


func anvil_pile() -> Dictionary:
	if storage.size() < 2 or int(storage[1].get("count", 0)) <= 0:
		return {}
	return storage[1]


func anvil_pile_count() -> int:
	return int(anvil_pile().get("count", 0))


## Would `item` go on the pile? Anything workable, as long as it is the SAME
## thing as what is already there -- one metal, one shape, one pile.
func anvil_pile_fits(item: Dictionary) -> bool:
	var id := int(item.get("id", Blocks.AIR))
	if not anvil_takes(id):
		return false
	var pile := anvil_pile()
	return pile.is_empty() or (int(pile["id"]) == id
		and str(pile.get("src", "")) == str(item.get("src", "")))


## Set `n` of `item` down on the pile. Returns how many went on.
func anvil_pile_add(item: Dictionary, n: int) -> int:
	if n <= 0 or not anvil_pile_fits(item):
		return 0
	_ensure_storage()
	var pile := anvil_pile()
	if pile.is_empty():
		var fresh: Dictionary = item.duplicate(true)
		fresh["count"] = n
		fresh.erase("eighths")
		fresh.erase("hits")
		storage[1] = fresh
	else:
		pile["count"] = int(pile["count"]) + n
	_refresh_anvil()
	return n


## The whole pile, taken back. Returns it as one item (or {} if there was none).
func anvil_pile_take() -> Dictionary:
	var pile := anvil_pile()
	if pile.is_empty():
		return {}
	var out: Dictionary = pile.duplicate(true)
	storage[1] = {"id": Blocks.AIR, "count": 0, "eighths": 0, "props": {},
		"src": "", "mat": {}}
	_refresh_anvil()
	return out


## With the face empty, slide the next one off the pile onto it. Returns
## whether one went on.
func anvil_feed() -> bool:
	if not anvil_piece().is_empty():
		return false
	var pile := anvil_pile()
	if pile.is_empty():
		return false
	var one: Dictionary = pile.duplicate(true)
	one["count"] = 1
	pile["count"] = int(pile["count"]) - 1
	if int(pile["count"]) <= 0:
		storage[1] = {"id": Blocks.AIR, "count": 0, "eighths": 0, "props": {},
			"src": "", "mat": {}}
	return anvil_put(one)


## How far through its current stage the piece is, 0..1 -- what the model uses
## to change a little with every blow between the big changes of shape.
func anvil_progress() -> float:
	var p := anvil_piece()
	if p.is_empty():
		return 0.0
	var st := Blocks.smith_stages(p.get("props", {}))
	var hits := int(p.get("hits", 0))
	var bounds := [0, int(st[0]), int(st[1]), int(st[2])]
	for i in 3:
		if hits < int(bounds[i + 1]):
			var lo := int(bounds[i])
			return float(hits - lo) / float(maxi(int(bounds[i + 1]) - lo, 1))
	return 0.0


## Can this go on the anvil? An ingot, or a bar or sheet to be carried on.
static func anvil_takes(id: int) -> bool:
	return Blocks.is_refined(id) or id == Blocks.BAR or id == Blocks.SHEET


## Put one of `item` on the face. It starts as far along as it already is: a
## bar goes on as a bar. Returns false if it is not something you can work.
func anvil_put(item: Dictionary) -> bool:
	var id := int(item.get("id", Blocks.AIR))
	if not anvil_takes(id) or not anvil_piece().is_empty():
		return false
	_ensure_storage()
	var piece: Dictionary = item.duplicate(true)
	piece["count"] = 1
	piece.erase("eighths")
	var mat: Dictionary = (piece.get("mat", {}) as Dictionary).duplicate()
	if Blocks.is_refined(id):
		# Remember the ingot it started as, so whatever it becomes can be
		# melted back into exactly that.
		mat["ingot"] = id
		mat["src0"] = str(piece.get("src", ""))
	piece["mat"] = mat
	piece["hits"] = Blocks.smith_hits_of(id, piece.get("props", {}))
	storage[0] = piece
	_refresh_anvil()
	return true


## Put a piece back exactly as it was, strikes and all -- for when taking it
## off turned out to have nowhere to go.
func anvil_put_back(piece: Dictionary) -> void:
	_ensure_storage()
	storage[0] = piece.duplicate(true)
	_refresh_anvil()


## One blow. Returns what the piece is now (see Blocks.smith_shape).
func anvil_strike() -> String:
	var p := anvil_piece()
	if p.is_empty():
		return ""
	var shape := anvil_shape()
	if shape != "scrap":
		p["hits"] = int(p.get("hits", 0)) + 1
		shape = anvil_shape()
	_refresh_anvil()
	return shape


## Take the piece off as whatever it has become, and clear the face. Returns
## the item(s) it comes off as: one ingot, bar, sheet or scrap -- or, at plate,
## however many plates this ore gives. A plate that had started to crack is
## still a plate: the warning was the warning.
func anvil_take() -> Array:
	var p := anvil_piece()
	if p.is_empty():
		return []
	var shape := anvil_shape()
	var props: Dictionary = p.get("props", {})
	var mat: Dictionary = p.get("mat", {})
	var out: Array = []
	match shape:
		"ingot":
			var back := scrap_to_ingot(p)
			out.append({"id": back["id"], "count": 1, "props": props,
				"src": back["src"], "mat": back["mat"]})
		"plate", "cracking":
			out.append({"id": Blocks.METAL, "count": Blocks.plate_yield(props),
				"props": props, "src": "", "mat": {}})
		_:
			var id: int = {"bar": Blocks.BAR, "sheet": Blocks.SHEET}.get(shape, Blocks.SCRAP)
			# Different metals must not stack into one, so the source names the
			# metal as well as where it was dug.
			out.append({"id": id, "count": 1, "props": props,
				"src": "%s:%s" % [str(mat.get("src0", "")), str(mat.get("name", ""))],
				"mat": mat})
	storage[0] = {"id": Blocks.AIR, "count": 0, "eighths": 0, "props": {},
		"src": "", "mat": {}}
	_refresh_anvil()
	return out


func _refresh_anvil() -> void:
	if kind != Blocks.ANVIL or headless or _mi == null:
		return
	var shape := anvil_shape()
	var hits := int(anvil_piece().get("hits", 0))
	var want := "%s|%d|%d" % [shape, hits, anvil_pile_count()]
	if want == _anvil_shown:
		return
	_anvil_shown = want
	var pile := anvil_pile()
	var pile_col: Color = (pile.get("mat", {}) as Dictionary).get("color", Color(0.7, 0.68, 0.64))
	_mi.mesh = StationModels.anvil_mesh(shape, anvil_colour(), anvil_progress(), hits,
		anvil_pile_count(), pile_col)


## Swing the lever toward where the switch is set.
func _tick_lever(delta: float) -> void:
	if _lever == null or not is_instance_valid(_lever):
		return
	var want: float = 1.0 if switched_on else 0.0
	if is_equal_approx(_lever_t, want):
		return
	_lever_t = move_toward(_lever_t, want, delta * 5.0)
	_lever.rotation.x = lever_angle(_lever_t)


## The battery in a Generator's cradle soaks up its output. This is the only way
## to get power off a planet, so it is deliberately the simplest possible
## action: seat one and wait. Switched off, nothing flows.
func _tick_batteries(delta: float) -> void:
	if kind != Blocks.GENERATOR or power <= 0.0 or not switched_on or not active:
		return
	if not gen_has_battery():
		return
	var slot: Dictionary = gen_battery()
	if not slot.has("props") or not (slot["props"] is Dictionary):
		slot["props"] = {}
	var props: Dictionary = slot["props"]
	var cap: float = Blocks.battery_capacity(props)
	var held: float = float(props.get("charge", 0.0))
	if held >= cap:
		return
	var moved: float = minf(minf(CHARGE_RATE * delta, cap - held), power)
	props["charge"] = held + moved
	power -= moved


## Can this go in a generator's cradle? Anything that holds power -- which,
## today, is a battery.
static func holds_power(id: int) -> bool:
	return id == Blocks.BATTERY


## Would a generator take `id` into bay `slot`? The cradle takes something that
## holds power, the hopper takes something that burns, and the odd slots left
## over from an older save take nothing new.
static func gen_accepts(slot: int, id: int, props: Dictionary) -> bool:
	if id == Blocks.AIR:
		return true
	if slot == 0:
		return holds_power(id)
	if slot == 1:
		return Blocks.is_fuel(id, props)
	return false


## Set the switch outright -- from a save -- with the lever already there
## rather than swinging to it as the world loads.
func set_switched(on: bool) -> void:
	switched_on = on
	_lever_t = 1.0 if on else 0.0
	if _lever != null and is_instance_valid(_lever):
		_lever.rotation.x = lever_angle(_lever_t)


## The lever's angle for a throw of `t` (0 off, 1 on). Down and out from the
## case when off, up and out when on, sweeping out in front of the face between
## the two rather than through the machine.
static func lever_angle(t: float) -> float:
	return lerpf(-2.6, -0.5, t)


## A generator saved when it was a six-slot bunker: put a battery in the
## cradle and fuel in the hopper, and keep the rest in slots after them so
## nothing that was in it is lost.
func migrate_generator() -> void:
	if kind != Blocks.GENERATOR:
		return
	var items: Array = []
	for sl in storage:
		if int(sl.get("count", 0)) > 0 or int(sl.get("eighths", 0)) > 0:
			items.append(sl)
	if storage.size() == 2 and gen_accepts(0, int(storage[0].get("id", Blocks.AIR)),
			storage[0].get("props", {})) and gen_accepts(1,
			int(storage[1].get("id", Blocks.AIR)), storage[1].get("props", {})) \
			and int(storage[0].get("count", 0)) <= 1:
		return
	storage = []
	_ensure_storage()
	var rest: Array = []
	for it in items:
		var d: Dictionary = it
		var id := int(d.get("id", Blocks.AIR))
		if holds_power(id) and int(storage[0]["count"]) == 0:
			storage[0] = d.duplicate(true)
			if int(d["count"]) > 1:
				storage[0]["count"] = 1
				var more: Dictionary = d.duplicate(true)
				more["count"] = int(d["count"]) - 1
				rest.append(more)
		elif Blocks.is_fuel(id, d.get("props", {})) and (int(storage[1]["count"]) == 0
				or (int(storage[1]["id"]) == id and storage[1].get("src", "") == d.get("src", ""))):
			if int(storage[1]["count"]) == 0:
				storage[1] = d.duplicate(true)
			else:
				storage[1]["count"] = int(storage[1]["count"]) + int(d["count"])
		else:
			rest.append(d)
	for r in rest:
		storage.append(r)


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
			sh.add_air(moved / SHIP_AIR_POWER)
		_refresh_bay()
		return


## Swing the lid toward whatever it is meant to be doing. Eased rather than
## snapped, and left alone entirely once it has got there.
const LID_ANGLE := 1.55       # radians, near enough straight up
const LID_SPEED := 4.5


func _tick_lid(delta: float) -> void:
	if _lid == null or not is_instance_valid(_lid):
		return
	var want: float = 1.0 if lid_open else 0.0
	if is_equal_approx(_lid_t, want):
		return
	_lid_t = move_toward(_lid_t, want, delta * LID_SPEED)
	# Ease it, so it lifts away and settles rather than running at one rate.
	var e: float = _lid_t * _lid_t * (3.0 - 2.0 * _lid_t)
	_lid.rotation.x = LID_ANGLE * e


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
	_tick_lid(delta)
	_tick_lever(delta)
	_tick_generator(delta)
	_tick_batteries(delta)
	_tick_power_bay(delta)
	_refresh_gen()
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
		var mprops: Dictionary = _yield_props(craft["reqs"])
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
