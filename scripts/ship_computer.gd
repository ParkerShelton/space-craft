class_name ShipComputer
extends RefCounted
## The voice in the nose of the ship.
##
## While the ship is wrecked it is the only tutorial this game has: right-click
## the cockpit and it lists what is wrong in the order worth fixing, says what
## each repair is made of and where that comes from, and ticks things off as you
## do them. Nothing here teaches controls or tells you to press W -- it gives
## you a reason to go and find rock, and the rest follows.
##
## Once the ship flies it stops being a checklist and becomes what a ship's
## computer should be: how the ship is doing, where you have been, and where you
## could go.

## One line of the systems check: what it is, whether it is done, and -- if not
## -- what to do about it.
class Item:
	var name := ""
	var done := false
	var detail := ""
	var hint := ""

	func _init(n: String, ok: bool, d := "", h := "") -> void:
		name = n
		done = ok
		detail = d
		hint = h


## Everything the ship needs before it will fly, in the order to do it in.
static func checklist(ship: Ship) -> Array:
	var out: Array = []
	var st: Dictionary = ship.get_status()
	var missing: Dictionary = ship.wreck_missing
	# 1. The hull. A ship with holes in it holds no air, whatever else works.
	# Only the CABIN has to be airtight: a wing that went with the crash is not
	# a hole in the room you breathe in, and counting it as one sent people off
	# to make twenty plates they did not need.
	var cabin: Dictionary = {}
	for c in ship.cabin_cells:
		cabin[c] = true
	var plates := 0
	var door_missing := false
	for v in missing:
		if Blocks.is_door(int(missing[v])):
			door_missing = true
		elif cabin.has(v):
			plates += 1
	out.append(Item.new("Hull sealed", plates == 0 and bool(st.get("sealed", false)),
		"%d metal plate%s needed" % [plates, "" if plates == 1 else "s"] if plates > 0 else "airtight",
		"Put a metal plate in each hole in the cabin."))
	# 2. A doorway with nothing in it is a hole like any other.
	out.append(Item.new("Door", not door_missing,
		"missing -- one needed" if door_missing else "fitted",
		"A Door is made at a Carpenter's Bench."))
	# 3. Power. Without it nothing else in here does anything. Power is not a
	# block you bolt in -- it is a battery you carry, charged somewhere else and
	# dropped into the rack. Saying so here is the only place the game ever
	# explains it, so it says it plainly.
	var bay := power_bay(ship)
	var held := battery_charge(bay)
	out.append(Item.new("Power", bay != null and held > 0.0,
		("no battery rack aboard" if bay == null
			else ("charged" if held > 0.0 else "rack empty" if not _bay_has_battery(bay)
				else "battery flat")),
		("A Power Bay is built at a Shipworks and mounts inside the hull."
			if bay == null
			else "Charge a battery in a Generator, then drop it in the rack.")))
	# 4. Air.
	var has_ls := bool(st.get("life_support", false))
	out.append(Item.new("Life support", has_ls,
		"fitted" if has_ls else "missing",
		"Salvage one, or build it at a Shipworks."))
	# 5. Thrust.
	var thr := int(st.get("thrusters", 0))
	out.append(Item.new("Thrusters", thr >= 2,
		"%d of 2" % thr,
		"Salvage one, or build it at a Shipworks."))
	# 6. Everything above, and the tanks full.
	var pressurised: bool = bool(st.get("habitable", false)) and float(st.get("air", 0.0)) > 0.05
	out.append(Item.new("Cabin pressurised", pressurised,
		"%d%% air" % int(float(st.get("air", 0.0)) * 100.0),
		"Seal the ship, fit life support and give it power: the cabin fills itself."))
	return out


static func _has(ship: Ship, id: int) -> bool:
	for v in ship.blocks:
		if int(ship.blocks[v]) == id:
			return true
	return false


## Is every line ticked?
static func flightworthy(ship: Ship) -> bool:
	for it in checklist(ship):
		if not (it as Item).done:
			return false
	return true


## The one thing worth doing next, in a sentence. This is what the computer
## says when you ask it rather than reading the list yourself.
static func next_step(ship: Ship) -> String:
	for it in checklist(ship):
		var item: Item = it
		if not item.done:
			return "%s: %s. %s" % [item.name, item.detail, item.hint]
	return "All systems nominal. The ship will fly."


## What the computer says when the ship is whole -- how it is doing, in lines.
static func status_lines(ship: Ship) -> Array:
	var st: Dictionary = ship.get_status()
	var out: Array = []
	out.append("Hull: %s" % ("airtight" if bool(st.get("sealed", false)) else "breached"))
	out.append("Air: %d%%" % int(float(st.get("air", 0.0)) * 100.0))
	out.append("Power: %d%%" % int(float(st.get("charge", 0.0)) * 100.0))
	out.append("Warp drive: %s" % ("fitted" if bool(st.get("warp_drive", false)) else "none"))
	out.append_array(flight_lines(ship))
	return out


## How she actually flies, which is a question about her weight and where her
## engines are, not about how many you bolted on.
static func flight_lines(ship: Ship) -> Array:
	var f: Dictionary = ship.flight_stats()
	var out: Array = []
	var n := int(f["thrusters"])
	var want := int(f["want_thrusters"])
	var accel := float(f["accel"])
	out.append("")
	out.append("Hull mass: %d" % int(round(float(f["mass"]))))
	out.append("Thrusters: %d fitted, %d for this mass" % [n, want])
	if n > 0:
		out.append("Thrust: %d total, %d each"
			% [int(round(float(f["thrust"]))), int(round(float(f["per_thruster"])))])
	out.append("Acceleration: %.1f  (%s)" % [accel, _accel_word(accel)])
	out.append("Trim: %s" % _trim_word(ship, float(f["trim_error"])))
	return out


## What that acceleration means, in words, so a number is a verdict.
static func _accel_word(accel: float) -> String:
	if accel < Ship.GOOD_ACCEL * 0.35:
		return "barely moves"
	if accel < Ship.GOOD_ACCEL * 0.7:
		return "sluggish"
	if accel < Ship.GOOD_ACCEL * 1.4:
		return "answers well"
	return "lively"


## Which way she pulls, and how badly. Naming the side is the difference
## between a complaint and something you can go and fix.
static func _trim_word(ship: Ship, err: float) -> String:
	if int(ship.flight_stats()["thrusters"]) <= 0:
		return "nothing fitted"
	if err <= 0.0:
		return "balanced"
	var t: Vector3 = ship.lateral_trim()
	var side := ""
	if absf(t.x) >= absf(t.y):
		side = "starboard" if t.x > 0.0 else "port"
	else:
		side = "high" if t.y > 0.0 else "low"
	var how := "slightly" if err < 1.0 else ("noticeably" if err < 2.5 else "badly")
	return "%s heavy to %s -- the ship will wander under power" % [how, side]


## The battery rack mounted in this ship, if it has one. Stations are children
## of the ship they are mounted on, so this is simply a look at its own nodes.
static func power_bay(ship: Ship) -> Station:
	for c in ship.get_children():
		var st := c as Station
		if st != null and is_instance_valid(st) and st.kind == Blocks.POWER_BAY:
			return st
	return null


## How much charge is sitting in the rack, across every battery in it.
static func battery_charge(bay: Station) -> float:
	if bay == null:
		return 0.0
	var total := 0.0
	for slot in bay.storage:
		if int(slot.get("id", Blocks.AIR)) == Blocks.BATTERY:
			total += float((slot.get("props", {}) as Dictionary).get("charge", 0.0))
	return total


## How much the battery in the rack COULD hold -- its own capacity, which comes
## from what it was made of.
static func bay_capacity(bay: Station) -> float:
	if bay == null:
		return 0.0
	var total := 0.0
	for slot in bay.storage:
		if int(slot.get("id", Blocks.AIR)) == Blocks.BATTERY:
			total += Blocks.battery_capacity(slot.get("props", {}))
	return total


static func _bay_has_battery(bay: Station) -> bool:
	if bay == null:
		return false
	for slot in bay.storage:
		if int(slot.get("id", Blocks.AIR)) == Blocks.BATTERY:
			return true
	return false
