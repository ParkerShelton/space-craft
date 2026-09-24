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

## Which piece of the airframe a cell belongs to. Everything but the nose can be
## torn off; only the cabin's own shell has to be airtight to fly.
enum { S_NOSE, S_CABIN, S_SPINE, S_BELLY, S_WING_L, S_WING_R, S_TAIL }


## Build the wreck and set it on the ground at `pos`, facing `fwd`.
static func build(world: WorldManager, pos: Vector3, up: Vector3, fwd: Vector3,
		rng: RandomNumberGenerator) -> Ship:
	var ship := world.spawn_ship(pos, up, fwd)
	ship.blocks.clear()
	var plan := _plan()
	for v in plan:
		ship.set_block(v, int(plan[v]))
	_wreck(ship, plan, rng)
	# The seat is a model rather than blocks: a thing you sit in, not a cube.
	ship.seat_at = Vector3(0, 1, CABIN_FRONT + 1.6)
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
	# The fuselage: a shell wrapped round a hollow cabin.
	for z in range(NOSE, TAIL + 1):
		var hw := _half_width(z)
		for x in range(-hw, hw + 1):
			for y in range(0, H + 1):
				var hollow := z > CABIN_FRONT and z < CABIN_BACK 					and absi(x) < hw and y > 0 and y < H
				if not hollow:
					out[Vector3i(x, y, z)] = Blocks.METAL
	# The nose: the console at eye level with a windscreen over and beside it.
	out[Vector3i(0, 1, CABIN_FRONT)] = Blocks.COCKPIT
	for x2 in [-1, 1]:
		out[Vector3i(x2, 1, CABIN_FRONT)] = Blocks.GLASS
	for x3 in range(-1, 2):
		out[Vector3i(x3, 2, CABIN_FRONT)] = Blocks.GLASS
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
	# The tail: a fin standing up and a stabiliser either side.
	for y2 in range(H, H + 3):
		out[Vector3i(0, y2, TAIL - 1)] = Blocks.METAL
		if y2 < H + 2:
			out[Vector3i(0, y2, TAIL)] = Blocks.METAL
	for side2 in [-1, 1]:
		out[Vector3i(side2 * 2, 2, TAIL)] = Blocks.METAL
		out[Vector3i(side2, 2, TAIL)] = Blocks.METAL
	# The works, along the back wall of the cabin.
	out[Vector3i(-1, 1, CABIN_BACK - 1)] = Blocks.LIFE_SUPPORT
	out[Vector3i(1, 1, CABIN_BACK - 1)] = Blocks.BATTERY
	out[Vector3i(0, 1, CABIN_BACK - 1)] = Blocks.WIRE
	# Thrusters on the tail.
	out[Vector3i(-1, 1, TAIL)] = Blocks.THRUSTER
	out[Vector3i(1, 1, TAIL)] = Blocks.THRUSTER
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
		if s == S_CABIN or s == S_SPINE or s == S_BELLY:
			out.append(v)
	return out


## Tear pieces off her. Whole sections go -- a wing, the tail -- what is left
## takes holes, and one or two systems go with them.
static func _wreck(ship: Ship, plan: Dictionary, rng: RandomNumberGenerator) -> void:
	var missing := {}
	var by_section := {}
	for v in plan:
		var s := section_of(v)
		if not by_section.has(s):
			by_section[s] = []
		(by_section[s] as Array).append(v)
	for s2 in [S_WING_L, S_WING_R, S_TAIL, S_SPINE, S_BELLY]:
		var cells: Array = by_section.get(s2, [])
		if cells.is_empty():
			continue
		cells.sort()
		var roll := rng.randf()
		# A wing is easily lost; the tail carries the thrusters and the belly is
		# what you stand on, so those are damaged more often than taken.
		var gone_odds: float = 0.35 if (s2 == S_WING_L or s2 == S_WING_R) else 0.12
		if roll < gone_odds:
			for v2 in cells:
				missing[v2] = int(plan[v2])
		elif roll < 0.8:
			for i in rng.randi_range(2, maxi(3, cells.size() / 3)):
				var pick: Vector3i = cells[rng.randi() % cells.size()]
				missing[pick] = int(plan[pick])
	# The cabin always takes a few, so there is always something to seal.
	var cabin: Array = by_section.get(S_CABIN, [])
	cabin.sort()
	if not cabin.is_empty():
		for i2 in rng.randi_range(2, 5):
			var pick2: Vector3i = cabin[rng.randi() % cabin.size()]
			missing[pick2] = int(plan[pick2])
	# More often than not the door is simply gone.
	if rng.randf() < 0.6:
		missing[DOOR_AT] = int(plan[DOOR_AT])
		missing[DOOR_AT + Vector3i(0, 1, 0)] = int(plan[DOOR_AT + Vector3i(0, 1, 0)])
	# Systems: the battery is always dead -- that is what put her down -- and one
	# or two of the rest went with it.
	var systems := [Vector3i(-1, 1, CABIN_BACK - 1), Vector3i(1, 1, CABIN_BACK - 1),
		Vector3i(0, 1, CABIN_BACK - 1), Vector3i(-1, 1, TAIL), Vector3i(1, 1, TAIL)]
	systems.shuffle()
	for i3 in mini(rng.randi_range(1, 3), systems.size()):
		var sv: Vector3i = systems[i3]
		if plan.has(sv):
			missing[sv] = int(plan[sv])
	# The nose comes through whatever else does not.
	for v3 in missing.keys():
		if section_of(v3) == S_NOSE:
			missing.erase(v3)
	for v4 in missing:
		ship.set_block(v4, Blocks.AIR)
	ship.wreck_missing = missing
	ship.cabin_cells = cabin_shell(plan)
	ship.charge = 0.0
	ship.air = 0.0
