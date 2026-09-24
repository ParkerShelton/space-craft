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

## Which piece of the airframe a cell belongs to. Everything but the nose can be
## torn off; only the cabin's own shell has to be airtight to fly.
enum { S_NOSE, S_CABIN, S_SPINE, S_BELLY, S_WING_L, S_WING_R, S_TAIL }


## Build the wreck and set it on the ground at `pos`, facing `fwd`.
static func build(world: WorldManager, pos: Vector3, up: Vector3, fwd: Vector3,
		rng: RandomNumberGenerator) -> Ship:
	var ship := world.spawn_ship(pos, up, fwd)
	ship.blocks.clear()
	# Straight into the block map and ONE rebuild at the end. set_block rebuilds
	# the whole ship -- mesh, collision and the airtightness flood fill -- every
	# time it is called, so laying two hundred cells that way took minutes.
	var plan := _plan()
	for v in plan:
		ship.blocks[v] = int(plan[v])
	_wreck(ship, plan, rng)
	_fit_systems(ship, world, rng)
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
	# Wings, swept back, a plate thick.
	for side in [-1, 1]:
		for i in range(1, 5):
			var span := 2 + i
			var sweep := CABIN_BACK - 4 + i
			for z2 in range(sweep, sweep + 2):
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
	for s2 in [S_WING_L, S_WING_R, S_TAIL]:
		var cells: Array = by_section.get(s2, [])
		if cells.is_empty():
			continue
		cells.sort()
		var roll := rng.randf()
		var gone_odds: float = 0.35 if (s2 == S_WING_L or s2 == S_WING_R) else 0.15
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
static func _fit_systems(ship: Ship, world: WorldManager, rng: RandomNumberGenerator) -> void:
	if rng.randf() < 0.55:
		ship.blocks[Vector3i(-1, 1, CABIN_BACK - 1)] = Blocks.LIFE_SUPPORT
	for side in [-1, 1]:
		if rng.randf() < 0.45:
			ship.blocks[Vector3i(side, 1, TAIL)] = Blocks.THRUSTER
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
		for slot in bay.storage:
			if int(slot.get("id", Blocks.AIR)) == Blocks.AIR:
				slot["id"] = Blocks.BATTERY
				slot["count"] = 1
				# The wreck's own cell has no material behind it, so it takes the
				# default capacity -- and a fraction of that is what is left.
				slot["props"] = {"charge": frac * Station.BATTERY_CAP}
				break
		bay._refresh_bay()
