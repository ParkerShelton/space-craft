class_name CrashSite
extends RefCounted
## The ship you woke up in, and the state you woke up in it.
##
## Every new world opens the same way: a lander on its belly with pieces torn
## off it, half its systems gone, and a computer in the nose that will tell you
## what it needs. What is BROKEN is rolled per world -- one wreck loses a wing
## and its tail, the next is nearly whole but has nothing left to power it -- so
## the repair is different every time.
##
## The shape is a plane rather than a box: a pointed nose with the console
## behind it, a cabin you can stand up in, wings out either side, and a tail
## with the thrusters on it. The NOSE never breaks -- you have to wake up
## somewhere and the computer has to be there to talk to you. Everything behind
## it can go: port wing, starboard wing, the tail, the spine over the cabin, the
## belly under it.
##
## Nothing here is scripted beyond that. The repairs are the ordinary game --
## plate into the hole, a door in the doorway, a thruster on the tail -- which
## is the point: teaching by having something to fix beats teaching by telling.

const NOSE := -6         # the tip
const TAIL := 5          # the last ring of the tail
const CABIN_FRONT := -3  # the bulkhead the console sits in
const CABIN_BACK := 2    # the back wall of the cabin
const H := 3             # shell roof; the cabin inside is two blocks tall
const DOOR_AT := Vector3i(2, 1, 1)
## Where the battery rack stands, on the deck at the back of the cabin.
const POWER_BAY_AT := Vector3i(0, 1, CABIN_BACK - 1)
## Where the scrubber is bolted, and where the engines hang. Named so that
## anything that wants to point at a missing part -- the repair holograms, for
## one -- knows where it would go rather than guessing.
const LIFE_SUPPORT_AT := Vector3i(-1, 1, CABIN_BACK - 1)


static func thruster_at(side: int) -> Vector3i:
	return Vector3i(side, 1, TAIL)


## Where the supply locker is bolted: beside the console, at the front of the
## cabin. It began next to the battery rack, which put it directly inboard of
## the door -- you could not get out past it -- and up here it is the second
## thing you see when your head comes up, which is where it belongs.
const LOCKER_AT := Vector3i(1, 1, CABIN_FRONT)

## Which piece of the airframe a cell belongs to. Everything but the nose can be
## torn off; only the cabin's own shell has to be airtight to fly.
enum { S_NOSE, S_CABIN, S_SPINE, S_BELLY, S_WING_L, S_WING_R, S_TAIL }


## Build the wreck and set it on the ground at `pos`, facing `fwd`.
static func build(world: WorldManager, pos: Vector3, up: Vector3, fwd: Vector3,
		planet: Planet, rng: RandomNumberGenerator) -> Ship:
	var ship := world.spawn_ship(pos, up, fwd)
	ship.blocks.clear()
	# Straight into the block map and ONE rebuild at the end. set_block rebuilds
	# the whole ship -- mesh, collision and the airtightness flood fill -- every
	# time it is called, so laying two hundred cells that way took minutes.
	var plan := _plan()
	for v in plan:
		ship.blocks[v] = int(plan[v])
	_wreck(ship, plan, rng)
	_fit_systems(ship, world, planet, rng)
	ship.rebuild()
	# The seat is a model rather than blocks: a thing you sit in, not a cube.
	# Block centre, standing ON the floor plate (its top is y = 1), facing the nose.
	ship.seat_at = Vector3(0.5, 1.0, CABIN_FRONT + 2.5)
	ship.build_props()
	ship.landed = true
	ship.flying = false
	return ship


## How wide the fuselage is at each station along its length: a point at the
## nose, full width through the cabin, narrowing again toward the tail.
static func _half_width(z: int) -> int:
	if z <= NOSE:
		return 0
	if z <= NOSE + 1:
		return 1
	if z <= CABIN_BACK + 1:
		return 2
	return 1


## The ship as it left the yard: cell -> block.
static func _plan() -> Dictionary:
	var out := {}
	# The fuselage: a shell wrapped round a hollow cabin. The hollow runs right
	# up into the nose, and the nose's skin is glazed -- so the windscreen looks
	# out at the world instead of at the back of a metal snout.
	for z in range(NOSE, TAIL + 1):
		var hw := _half_width(z)
		for x in range(-hw, hw + 1):
			for y in range(0, H + 1):
				var hollow := z > NOSE + 1 and z < CABIN_BACK 					and absi(x) < hw and y > 0 and y < H
				if hollow:
					continue
				# Glazed above the belly plate from the bulkhead forward: the
				# canopy you sit behind.
				var id := Blocks.METAL
				if z <= CABIN_FRONT and y > 0:
					id = Blocks.GLASS
				out[Vector3i(x, y, z)] = id
	# The console, standing at the front of the cockpit with the glass round it.
	out[Vector3i(0, 1, CABIN_FRONT)] = Blocks.COCKPIT
	# A door you can walk through: two blocks tall, in the starboard side.
	out[DOOR_AT] = Blocks.door_with(false, 0, 0, false)
	out[DOOR_AT + Vector3i(0, 1, 0)] = Blocks.door_with(false, 0, 0, true)
	# Wings, swept back, a plate thick and three deep. The extra row is what
	# lets a wing that comes off lie over something -- a locker thrown out in
	# the crash, a thruster that tore loose -- rather than being too narrow to
	# hide anything under.
	for side in [-1, 1]:
		for i in range(1, 5):
			var span := 2 + i
			var sweep := CABIN_BACK - 4 + i
			for z2 in range(sweep - 1, sweep + 2):
				out[Vector3i(side * span, 1, z2)] = Blocks.METAL
	# Nothing stands in the doorway. The wing root runs right down the side she
	# is hinged in, so the chord across the door comes out -- which is where the
	# clearance for a door would have been cut anyway.
	for ox in range(DOOR_AT.x + 1, 8):
		for oy in [DOOR_AT.y, DOOR_AT.y + 1]:
			out.erase(Vector3i(ox, oy, DOOR_AT.z))
	# The tail: a fin standing up and a stabiliser either side.
	for y2 in range(H, H + 3):
		out[Vector3i(0, y2, TAIL - 1)] = Blocks.METAL
		if y2 < H + 2:
			out[Vector3i(0, y2, TAIL)] = Blocks.METAL
	for side2 in [-1, 1]:
		out[Vector3i(side2 * 2, 2, TAIL)] = Blocks.METAL
		out[Vector3i(side2, 2, TAIL)] = Blocks.METAL
	# Machinery is NOT in the plan. What she still has aboard is rolled per
	# world in _fit_systems -- a wreck with both thrusters and no air, or air
	# and nothing to power it, or now and then very little at all.
	# A lamp, so the first thing you see is not the dark.
	out[Vector3i(0, H, 0)] = Blocks.GLOW_LAMP
	return out


## Which piece of the airframe this cell is part of.
static func section_of(v: Vector3i) -> int:
	if v.z <= CABIN_FRONT:
		return S_NOSE
	if v.z >= TAIL - 1 or v.y > H:
		return S_TAIL
	if absi(v.x) > 2:
		return S_WING_L if v.x < 0 else S_WING_R
	if v.y == 0:
		return S_BELLY
	if v.y == H:
		return S_SPINE
	return S_CABIN


## The cells that have to be solid before the cabin will hold air. The wings and
## the tail can be missing altogether and she will still pressurise.
static func cabin_shell(plan: Dictionary) -> Array:
	var out: Array = []
	for v in plan:
		var s := section_of(v)
		if s != S_CABIN and s != S_SPINE and s != S_BELLY:
			continue
		# Only the SHELL. The fittings standing inside the room are not what
		# holds the air in, and counting them made the computer ask for metal
		# plates to replace a thruster.
		var id := int(plan[v])
		if id != Blocks.METAL and id != Blocks.GLASS and not Blocks.is_door(id):
			continue
		out.append(v)
	return out


## Tear pieces off her. Whole sections go -- a wing, the tail -- what is left
## takes holes, and one or two systems go with them.
static func _wreck(ship: Ship, plan: Dictionary, rng: RandomNumberGenerator) -> void:
	var missing := {}
	var by_section := {}
	for v in plan:
		# The door is NOT a hole candidate. It is two cells and it has a roll of
		# its own below, all or nothing; leaving it in here let the cabin roll
		# pick out one half and leave the other, so she came down with a door
		# that was only a bottom and a gap you could see daylight through.
		if Blocks.is_door(int(plan[v])):
			continue
		var s := section_of(v)
		if not by_section.has(s):
			by_section[s] = []
		(by_section[s] as Array).append(v)
	# Only the pieces that stand proud of the cabin can be torn off whole: a
	# wing, or the tail. The roof and the floor take holes and no more -- they
	# are what has to be made airtight again, and nobody should wake to a
	# shopping list of thirty plates.
	var torn: Array = []
	# One wing ALWAYS comes off. What lands out there is where the salvage is
	# -- metal to cut, and whatever it came down on top of -- and an opening
	# with nothing lying around it has nothing to walk out to.
	var lost_wing: int = S_WING_L if rng.randf() < 0.5 else S_WING_R
	for s2 in [S_WING_L, S_WING_R, S_TAIL]:
		var cells: Array = by_section.get(s2, [])
		if cells.is_empty():
			continue
		cells.sort()
		var roll := rng.randf()
		var gone_odds: float = 0.35 if (s2 == S_WING_L or s2 == S_WING_R) else 0.15
		if s2 == lost_wing:
			roll = 0.0
		if roll < gone_odds:
			for v2 in cells:
				missing[v2] = int(plan[v2])
			# It did not evaporate: it is lying out there somewhere.
			torn.append(cells.duplicate())
		elif roll < 0.8:
			for i in rng.randi_range(2, maxi(3, cells.size() / 3)):
				var pick: Vector3i = cells[rng.randi() % cells.size()]
				missing[pick] = int(plan[pick])
	# The ROOF takes holes; the floor never does. A hole in the belly is one you
	# fall through, and waking up somewhere you drop out of the bottom of is not
	# a puzzle, it is a trap.
	for s3 in [S_SPINE]:
		var shell: Array = by_section.get(s3, [])
		if shell.is_empty():
			continue
		shell.sort()
		for i2 in rng.randi_range(1, 4):
			var pick3: Vector3i = shell[rng.randi() % shell.size()]
			missing[pick3] = int(plan[pick3])
	# The cabin always takes a few, so there is always something to seal.
	var cabin: Array = by_section.get(S_CABIN, [])
	cabin.sort()
	if not cabin.is_empty():
		for i4 in rng.randi_range(2, 5):
			var pick2: Vector3i = cabin[rng.randi() % cabin.size()]
			missing[pick2] = int(plan[pick2])
	# More often than not the door is simply gone.
	if rng.randf() < 0.6:
		missing[DOOR_AT] = int(plan[DOOR_AT])
		missing[DOOR_AT + Vector3i(0, 1, 0)] = int(plan[DOOR_AT + Vector3i(0, 1, 0)])
	# The nose comes through whatever else does not.
	for v3 in missing.keys():
		if section_of(v3) == S_NOSE:
			missing.erase(v3)
	for v4 in missing:
		ship.blocks.erase(v4)
	_ensure_way_out(ship, plan, missing)
	ship.wreck_debris = torn
	ship.wreck_missing = missing
	ship.cabin_cells = cabin_shell(plan)
	ship.charge = 0.0
	ship.air = 0.0


## Nobody is sealed in. The doorway is a way out whether the door went with the
## crash (a two-block hole) or survived (you open it) -- but a door can be
## painted over by a later roll, and a wreck you cannot leave is the one bug
## this opening must never have. So it is checked rather than assumed, and if
## the check fails the port wall loses two stacked cells and that is the way
## out instead.
static func _ensure_way_out(ship: Ship, plan: Dictionary, missing: Dictionary) -> void:
	if _way_out_exists(ship):
		return
	var y := 1
	while y <= H - 1:
		var hole := Vector3i(-2, y, 0)
		if plan.has(hole):
			missing[hole] = int(plan[hole])
			ship.blocks.erase(hole)
		y += 1


## Is there a standing-height gap in the cabin wall, or a door in it? Two cells
## stacked, because a one-block slot is not a way out for someone your size.
static func _way_out_exists(ship: Ship) -> bool:
	for z in range(CABIN_FRONT, CABIN_BACK + 1):
		for x in [-2, 2]:
			if _open_pair(ship, Vector3i(x, 1, z)):
				return true
	for x2 in range(-2, 3):
		if _open_pair(ship, Vector3i(x2, 1, CABIN_BACK)):
			return true
	return false


static func _open_pair(ship: Ship, v: Vector3i) -> bool:
	return _passable(ship, v) and _passable(ship, v + Vector3i(0, 1, 0))


static func _passable(ship: Ship, v: Vector3i) -> bool:
	if not ship.blocks.has(v):
		return true
	return Blocks.is_door(int(ship.blocks[v]))


## What she still has aboard, rolled one fitting at a time so no two worlds open
## on the same shopping list. Nothing is guaranteed: a wreck can keep both
## thrusters and lose its air, keep its air and have nothing to power it, or
## come down with hardly anything left in her at all.
##
## Power is a POWER BAY with a battery in it rather than a battery bolted to the
## wall, because that is how power actually works in this game: a battery is a
## thing you carry. You fill one at a Generator, drop it in the bay, and the bay
## feeds the ship -- so a spare in a chest is a ship that never goes dark.
static func _fit_systems(ship: Ship, world: WorldManager, planet: Planet,
		rng: RandomNumberGenerator) -> void:
	# A locker, always, with enough in it to last the first night and to put a
	# bench down without having to find a tree first. It is the one thing in the
	# wreck that is not damaged: you are meant to open it, find it stocked, and
	# understand from that that somebody packed it.
	# Facing AFT, into the cabin: a locker whose clasp is against the nose is a
	# locker you cannot open without walking through the windscreen.
	var locker := world.spawn_station_on_ship(Blocks.CHEST, ship, LOCKER_AT,
		Vector3i(0, 0, 1))
	if locker != null:
		locker.store_add(Blocks.COOKED_MEAT, 4, {})
		locker.store_add(Blocks.TORCH, 3, {})
		locker.store_add(Blocks.WOOD, 6, {})
		locker.store_add(Blocks.ROCK, 6, {})
		# The journal is NOT in here. It goes into your hands (see
		# Main._place_crash_site): the whole of this game's teaching was sitting
		# inside a box you had to notice, open and then read, and a player who
		# climbed out of the hole and walked off had nothing at all. It points
		# back at this locker instead, which is the right way round.
	var has_ls := rng.randf() < 0.55
	var thr := {-1: rng.randf() < 0.45, 1: rng.randf() < 0.45}
	# A FLOOR: something aboard is always missing. A wreck that came down with
	# its air and both engines teaches you to plate a hole and nothing else,
	# and the parts are the half of the opening worth learning.
	if has_ls and thr[-1] and thr[1]:
		var lose := rng.randi() % 3
		if lose == 0:
			has_ls = false
		else:
			thr[-1 if lose == 1 else 1] = false
	if has_ls:
		ship.blocks[LIFE_SUPPORT_AT] = Blocks.LIFE_SUPPORT
	for side in [-1, 1]:
		if thr[side]:
			ship.blocks[thruster_at(side)] = Blocks.THRUSTER
	# ...and a CEILING, below: a flat battery on top of no air and no engines is
	# the whole tech tree before you can fly, on day one.
	var stripped: bool = not has_ls and not thr[-1] and not thr[1]
	# The cradle and a battery in it, always. Leaving without one meant building
	# a Generator before you could build anything else, and the first hour of a
	# world should not be a list of prerequisites. What VARIES is how much is
	# left in it: enough to go, enough to get started, or flat -- and a flat one
	# is what sends you looking for a Generator, which is the lesson.
	var bay := world.spawn_station_on_ship(Blocks.POWER_BAY, ship, POWER_BAY_AT)
	if bay != null:
		var roll := rng.randf()
		var frac: float = 0.0
		if roll > 0.2:
			frac = rng.randf_range(0.12, 0.85)
		elif stripped:
			# She lost everything else: leave her a little in the battery, so
			# the generator is a later job rather than the first of many.
			frac = rng.randf_range(0.15, 0.3)
		for slot in bay.storage:
			if int(slot.get("id", Blocks.AIR)) == Blocks.AIR:
				slot["id"] = Blocks.BATTERY
				slot["count"] = 1
				# The wreck's own cell has no material behind it, so it takes the
				# default capacity -- and a fraction of that is what is left.
				slot["props"] = {"charge": frac * Station.BATTERY_CAP}
				break
		bay._refresh_bay()


## The survey you wrote on the way in.
##
## Not a random page of flavour: it is written FROM this planet -- its real day
## length, whether it has water, the ores it actually has and what each of them
## is good for -- plus what to do if the landing goes badly, in the order that
## works. So it reads as a thing you wrote about somewhere you were about to
## land, and every line of it is true of the world you are standing in.
##
## It is the whole tutorial, and it never once says "press" anything.
static func journal_text(planet: Planet) -> String:
	var lines: Array = []
	lines.append("APPROACH SURVEY -- %s" % planet.planet_name)
	lines.append("")
	lines.append("THE GROUND")
	var day_min: float = planet.day_length * planet.DAY_SHARE / 60.0
	var night_min: float = planet.day_length * (1.0 - planet.DAY_SHARE) / 60.0
	lines.append("Light for about %d minutes, then dark for %d."
		% [int(round(day_min)), int(round(night_min))])
	lines.append("Do not be out past dark even with a light.")
	lines.append("I have no confirmation but things are awake in the night.")
	if planet.water_style == planet.WATER_LIQUID:
		lines.append("There's liquid water. Wood floats here too, which is worth knowing.")
	else:
		lines.append("No standing water anywhere I could see.")
	lines.append("")
	# Counts and what they are FOR, not an inventory. Which ore is which is
	# something to find out on the ground; how many there are and whether this
	# world can power anything is what you want to know before landing.
	if not planet.ore_defs.is_empty():
		lines.append("THE ORES")
		var metal := 0
		var spark := 0
		var burn := 0
		for od in planet.ore_defs:
			match _ore_use(od["props"]):
				"power":
					burn += 1
				"electrical":
					spark += 1
				_:
					metal += 1
		lines.append("%s of ore down there." % _count_word(planet.ore_defs.size()))
		if metal > 0:
			lines.append("  %s best for metalwork." % _count_word(metal))
		if spark > 0:
			lines.append("  %s best for electrical work." % _count_word(spark))
		if burn > 0:
			lines.append("  %s worth burning for power. The stone round" % _count_word(burn))
			lines.append("  those is black and sooty -- you can pick the patch")
			lines.append("  out from across a cave.")
		if burn == 0:
			lines.append("  None of it burns well. Power will be the hard part.")
		lines.append("A furnace is a fire with a chamber over it, and the fire")
		lines.append("is the part I have to keep. Wood in the grate at the front,")
		lines.append("ore in the chamber above it. No fire, no smelt -- it will")
		lines.append("sit there cold with the ore in it and wait for me. Coal")
		lines.append("and any ore that burns go in the grate too, and last far")
		lines.append("longer than wood does.")
		lines.append("Smelt ore into ingots, then hammer an ingot flat on an")
		lines.append("anvil to get different things. Too much hammering ruins the metal.")
		lines.append("The ore that burns has no metal in it -- the same furnace")
		lines.append("bakes that down to coal, which is worth far more in a")
		lines.append("generator than the raw rock is.")
		lines.append("Machines are built from the plates; four of them")
		lines.append("pressed together make a block of hull.")
		lines.append("")
		lines.append("WHAT THE FIVE READINGS MEAN")
		lines.append("Every ore assays at five figures, each out of a hundred.")
		lines.append("")
		lines.append("HARDNESS -- how stubborn it is under the hammer. A hard")
		lines.append("  ore takes more blows to work into anything, but it holds")
		lines.append("  a cleaner bore, so pipe drawn from it runs faster.")
		lines.append("DENSITY -- how much metal is actually in the rock. Dense")
		lines.append("  ore casts more plates from the same ingot, and makes")
		lines.append("  everything built out of it heavier, which the thrusters")
		lines.append("  will have opinions about.")
		lines.append("ENERGY -- how much there is in it to let go of. This is")
		lines.append("  thruster push, and how long and how hard a fuel rod")
		lines.append("  runs in a reactor.")
		lines.append("REACTIVITY -- how willingly it carries a current. It sets")
		lines.append("  how much wire a bar draws out, how much charge a battery")
		lines.append("  will hold, and how well a solar panel works. Past about")
		lines.append("  half, the raw ore glows in the dark on its own -- which")
		lines.append("  is how you find the good stuff at night.")
		lines.append("COMBUSTION -- how readily it burns. Over about half and it")
		lines.append("  is fuel rather than metal: sooty stone, bakes down to")
		lines.append("  coal, and no good for casting at all.")
		lines.append("")
		lines.append("Nothing is good at all five, and the ores that burn best")
		lines.append("are the worst castings on the planet. Worth knowing before")
		lines.append("I fill a chest with the wrong rock.")
		lines.append("")
		lines.append("And every way of making power asks a DIFFERENT one of")
		lines.append("them. A burner wants Combustion. A solar panel wants")
		lines.append("Reactivity. A reactor rod wants Energy. The pile that ran")
		lines.append("the last machine will not run the next one.")
		lines.append("")
		lines.append("THE ASSAY")
		lines.append("Off the scope on the way in. Names only -- I will have to")
		lines.append("work out what each one looks like in the ground.")
		for od in planet.ore_defs:
			var op: Dictionary = od["props"]
			lines.append("")
			lines.append(str(od["name"]).to_upper())
			lines.append("  Hardness %d%%   Density %d%%   Energy %d%%"
				% [int(op.get("h", 0)), int(op.get("d", 0)), int(op.get("e", 0))])
			lines.append("  Reactivity %d%%   Combustion %d%%"
				% [int(op.get("r", 0)), int(op.get("c", 0))])
			lines.append("  %s" % _ore_note(op))
		lines.append("")
	lines.append("IF THE LANDING GOES BADLY")
	lines.append("Seal the ship before anything else: a block of hull in every")
	lines.append("hole, and a door in the doorway. Nothing aboard the ship")
	lines.append("works until it holds air.")
	lines.append("")
	lines.append("Anything that breaks off the ship on the way down is still")
	lines.append("hull. Cut up the wings before you dig for ore -- that hull")
	lines.append("is already lying on the ground.")
	lines.append("")
	lines.append("The battery in the rack is what powers the ship. An empty")
	lines.append("battery is not a broken one: charge it at a generator and")
	lines.append("put it back.")
	lines.append("")
	lines.append("There is a small chest bolted down beside the console with")
	lines.append("enough in it for the first day: some food, torches, and a")
	lines.append("little wood and rock to get me going.")
	return "
".join(PackedStringArray(lines))


## The line under an ore's figures: what it is FOR, in words, so the numbers
## above it mean something before you have used any of them.
static func _ore_note(props: Dictionary) -> String:
	match _ore_use(props):
		"power":
			return "Burns. Fuel, not metal -- bake it down to coal."
		"electrical":
			return "Carries a current. Wire, batteries, solar."
		_:
			if int(props.get("d", 0)) >= 60:
				return "Heavy and inert. The best plate here."
			return "Workable metal. Plates, tools, hull."


## What an ore is mostly good for. One answer each -- the survey is a summary,
## not a table.
static func _ore_use(props: Dictionary) -> String:
	if Blocks.is_fuel_grade(props):
		return "power"
	if Blocks.conductivity_of(props) >= 55:
		return "electrical"
	return "metalwork"


static func _count_word(n: int) -> String:
	const WORDS := ["No kinds", "One kind", "Two kinds", "Three kinds",
		"Four kinds", "Five kinds", "Six kinds"]
	if n >= 0 and n < WORDS.size():
		return WORDS[n]
	return "%d kinds" % n
