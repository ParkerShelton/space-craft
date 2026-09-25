class_name ShipPanels
extends RefCounted
## The little screens on the side of a ship's fittings.
##
## The cockpit has the ship's computer, which talks about the whole hull. These
## are the opposite: right-click one part -- the scrubber, an engine, the warp
## drive -- and it tells you about ITSELF. Whether it has power, what it is
## doing with it, and how much of whatever it holds is left.
##
## None of them have an inventory. There is nothing to put into a scrubber, so
## asking you to look at eight empty slots to find out how much air is in the
## tank would be a worse screen, not a richer one. They are gauges.
##
## Each builder returns a Control. Nothing here touches the player or the world:
## it is handed a ship and a cell and reads them, so the whole file can be
## deleted without anything else noticing.

const DIM := Color(1, 1, 1, 0.55)
const CYAN := Color(0.55, 0.90, 1.00)
const WARN := Color(1.00, 0.72, 0.35)
const BAD := Color(1.00, 0.45, 0.42)
const GOOD := Color(0.55, 0.95, 0.65)
const PANEL_W := 460


## Is this a fitting with a screen of its own?
static func has_panel(id: int) -> bool:
	match Blocks.bottom_of(id):
		Blocks.LIFE_SUPPORT, Blocks.THRUSTER, Blocks.WARP_DRIVE:
			return true
		_:
			return false


static func title_of(id: int) -> String:
	match Blocks.bottom_of(id):
		Blocks.LIFE_SUPPORT: return "LIFE SUPPORT"
		Blocks.THRUSTER: return "ENGINE"
		Blocks.WARP_DRIVE: return "WARP DRIVE"
		_: return Blocks.name_of(id).to_upper()


## What the screen currently says, as one string, so a panel that would redraw
## to the same thing is left alone -- and the buttons on it stay clickable.
static func signature(ship: Ship, cell: Vector3i, id: int) -> String:
	if ship == null or not is_instance_valid(ship):
		return ""
	var st := ship.get_status()
	match Blocks.bottom_of(id):
		Blocks.LIFE_SUPPORT:
			return "ls|%d|%d|%s|%s|%d" % [int(ship.air * 200.0), int(ship.charge * 200.0),
				st.get("sealed", false), st.get("habitable", false), int(ship.air_made)]
		Blocks.THRUSTER:
			var f := ship.flight_stats()
			return "th|%d|%d|%d|%d" % [int(ship.thruster_output(cell)),
				int(f["thrust"]), int(f["mass"]), int(f["trim_error"] * 100.0)]
		Blocks.WARP_DRIVE:
			return "wd|%d|%s" % [int(ship.charge * 200.0), st.get("habitable", false)]
	return "?"


## The screen for one fitting.
static func build(ship: Ship, cell: Vector3i, id: int) -> Control:
	var vb := VBoxContainer.new()
	vb.custom_minimum_size = Vector2(PANEL_W, 0)
	vb.add_theme_constant_override("separation", 6)
	match Blocks.bottom_of(id):
		Blocks.LIFE_SUPPORT: _life_support(vb, ship)
		Blocks.THRUSTER: _thruster(vb, ship, cell)
		Blocks.WARP_DRIVE: _warp(vb, ship)
	return vb


# --- the three screens ---------------------------------------------------------

## The scrubber. The big dial is the cabin tank, because that is the number you
## came to look at; everything under it explains why the needle is where it is.
static func _life_support(vb: VBoxContainer, ship: Ship) -> void:
	var st := ship.get_status()
	var powered: bool = ship.charge > 0.0
	var sealed: bool = bool(st.get("sealed", false))
	var running: bool = powered and sealed

	status_line(vb, "SCRUBBERS",
		"running" if running else ("no power" if not powered else "cabin is open"),
		GOOD if running else (BAD if not powered else WARN))

	var row := HBoxContainer.new()
	row.add_theme_constant_override("separation", 18)
	vb.add_child(row)
	row.add_child(dial(ship.air, "CABIN AIR", _air_colour(ship.air)))

	var side := VBoxContainer.new()
	side.add_theme_constant_override("separation", 5)
	row.add_child(side)
	stat(side, "In the tank", "%d of %d L" % [roundi(ship.air * Ship.AIR_LITRES),
		int(Ship.AIR_LITRES)])
	stat(side, "Put out, all told", "%d L" % roundi(ship.air_made))
	stat(side, "Breathed", "%d L" % roundi(ship.air_used))
	stat(side, "Hours run", _hms(ship.air_runtime))
	var draw_rate: float = Ship.AIR_DRAIN * (1.0 if powered else 2.0) * Ship.AIR_LITRES
	stat(side, "Draw while aboard", "%.1f L/s" % draw_rate)
	var left: float = ship.air * Ship.AIR_LITRES / maxf(draw_rate, 0.001)
	stat(side, "Endurance", _hms(left) if ship.air > 0.0 else "none",
		_air_colour(ship.air))

	vb.add_child(gap(4))
	vb.add_child(bar("SHIP POWER", ship.charge,
		GOOD if ship.charge > 0.25 else (WARN if ship.charge > 0.0 else BAD)))
	vb.add_child(gap(2))
	var note := ""
	if not sealed:
		note = "The cabin is not airtight. Plate every hole and shut the door, or the scrubbers are filling the sky."
	elif not powered:
		note = "No power. The tank is going twice as fast without the scrubbers on it. Charge a battery and put it in the power bay."
	elif ship.air < 0.25:
		note = "Nearly empty. A charged battery in the power bay refills the tank once the ship's power is topped up."
	else:
		note = "Air is only spent while you are aboard. A parked ship holds what it has."
	vb.add_child(note(note))


## One engine. Its own output first, then what the ship makes of it -- an engine
## is only ever as useful as the hull it is bolted to.
static func _thruster(vb: VBoxContainer, ship: Ship, cell: Vector3i) -> void:
	var f := ship.flight_stats()
	var mine: float = ship.thruster_output(cell)
	var total: float = float(f["thrust"])
	var powered: bool = ship.charge > 0.0
	status_line(vb, "ENGINE", "ready" if powered else "no power",
		GOOD if powered else BAD)

	var row := HBoxContainer.new()
	row.add_theme_constant_override("separation", 18)
	vb.add_child(row)
	# Against the best a thruster can be, not against the ship: this dial is
	# "how good is THIS engine", which is a question about the ore it was made
	# from and nothing else.
	var grade: float = clampf(mine / (Ship.THRUST_UNIT * 1.4), 0.0, 1.0)
	row.add_child(dial(grade, "OUTPUT", GOOD if grade > 0.6 else WARN))

	var side := VBoxContainer.new()
	side.add_theme_constant_override("separation", 5)
	row.add_child(side)
	stat(side, "This engine", "%d kN" % roundi(mine))
	stat(side, "Share of the ship", "%d%%" % roundi(mine / maxf(total, 0.001) * 100.0))
	stat(side, "Engines fitted", "%d of %d wanted" % [int(f["thrusters"]),
		int(f["want_thrusters"])],
		GOOD if int(f["thrusters"]) >= int(f["want_thrusters"]) else WARN)
	stat(side, "Ship mass", "%d t" % roundi(float(f["mass"]) / 1000.0))
	stat(side, "Acceleration", "%.1f m/s2" % float(f["accel"]),
		GOOD if float(f["accel"]) >= Ship.GOOD_ACCEL else WARN)
	var err: float = float(f["trim_error"])
	stat(side, "Balance", "even" if err <= 0.0 else "%.1f blocks off" % err,
		GOOD if err <= 0.0 else WARN)

	vb.add_child(gap(4))
	vb.add_child(bar("THRUST AGAINST WEIGHT",
		clampf(float(f["accel"]) / Ship.GOOD_ACCEL, 0.0, 1.0),
		GOOD if float(f["accel"]) >= Ship.GOOD_ACCEL else WARN))
	vb.add_child(gap(2))
	var note := ""
	if int(f["thrusters"]) < int(f["want_thrusters"]):
		note = "Underpowered for this hull. Fit %d more, or take weight off." % \
			(int(f["want_thrusters"]) - int(f["thrusters"]))
	elif err > 0.0:
		note = "The push is off to one side of the weight, so the ship wanders under thrust. An engine on the light side straightens it."
	else:
		note = "Good for this hull. Add hull and it will want more engines."
	vb.add_child(note(note))


static func _warp(vb: VBoxContainer, ship: Ship) -> void:
	var ready: bool = ship.charge >= 0.5
	status_line(vb, "WARP DRIVE", "charged" if ready else "charging",
		GOOD if ready else WARN)
	var row := HBoxContainer.new()
	row.add_theme_constant_override("separation", 18)
	vb.add_child(row)
	row.add_child(dial(ship.charge, "COILS", GOOD if ready else WARN))
	var side := VBoxContainer.new()
	side.add_theme_constant_override("separation", 5)
	row.add_child(side)
	stat(side, "Stored power", "%d%%" % roundi(ship.charge * 100.0))
	stat(side, "Needed to jump", "50%")
	stat(side, "Jump", "ready" if ready else "not yet", GOOD if ready else WARN)
	vb.add_child(gap(4))
	vb.add_child(note("Set a course from the pilot's seat. The drive takes its power from the same store life support runs on, so a jump costs you air time."))


# --- the pieces they are drawn from --------------------------------------------

static func _air_colour(v: float) -> Color:
	return GOOD if v > 0.5 else (WARN if v > 0.15 else BAD)


static func gap(h: int) -> Control:
	var c := Control.new()
	c.custom_minimum_size = Vector2(0, h)
	return c


static func status_line(vb: VBoxContainer, what: String, state: String, col: Color) -> void:
	var h := HBoxContainer.new()
	h.add_theme_constant_override("separation", 10)
	vb.add_child(h)
	var a := Label.new()
	a.text = what
	a.add_theme_font_size_override("font_size", 13)
	a.modulate = DIM
	h.add_child(a)
	var b := Label.new()
	b.text = state.to_upper()
	b.add_theme_font_size_override("font_size", 13)
	b.modulate = col
	h.add_child(b)


## A name on the left, a figure on the right, lined up down the column.
static func stat(vb: VBoxContainer, what: String, value: String,
		col: Color = Color(1, 1, 1, 0.92)) -> void:
	var h := HBoxContainer.new()
	vb.add_child(h)
	var a := Label.new()
	a.text = what
	a.custom_minimum_size = Vector2(150, 0)
	a.add_theme_font_size_override("font_size", 14)
	a.modulate = DIM
	h.add_child(a)
	var b := Label.new()
	b.text = value
	b.add_theme_font_size_override("font_size", 14)
	b.modulate = col
	h.add_child(b)


## The round gauge. Drawn rather than built out of Panels, because a needle
## swinging round an arc says "how full" at a glance in a way a number cannot,
## and this is a screen you look at with an alarm going.
static func dial(frac: float, caption: String, col: Color) -> Control:
	var c := Control.new()
	c.custom_minimum_size = Vector2(150, 150)
	var v := clampf(frac, 0.0, 1.0)
	c.draw.connect(func() -> void:
		var mid := Vector2(75, 78)
		var r := 54.0
		var a0 := deg_to_rad(140.0)
		var a1 := deg_to_rad(400.0)
		c.draw_arc(mid, r, a0, a1, 64, Color(1, 1, 1, 0.13), 9.0, true)
		c.draw_arc(mid, r, a0, lerpf(a0, a1, v), 64, col, 9.0, true)
		# Ticks every tenth, so the needle sits somewhere rather than nowhere.
		for i in 11:
			var a: float = lerpf(a0, a1, float(i) / 10.0)
			var d := Vector2(cos(a), sin(a))
			var long: bool = (i % 5) == 0
			c.draw_line(mid + d * (r - 14.0), mid + d * (r - (9.0 if long else 5.0)),
				Color(1, 1, 1, 0.30 if long else 0.16), 2.0)
		var na: float = lerpf(a0, a1, v)
		var nd := Vector2(cos(na), sin(na))
		c.draw_line(mid - nd * 8.0, mid + nd * (r - 17.0), col, 3.0)
		c.draw_circle(mid, 5.0, col)
		var fnt := ThemeDB.fallback_font
		var pct := "%d%%" % roundi(v * 100.0)
		var w := fnt.get_string_size(pct, HORIZONTAL_ALIGNMENT_LEFT, -1, 26).x
		c.draw_string(fnt, mid + Vector2(-w * 0.5, 34.0), pct,
			HORIZONTAL_ALIGNMENT_LEFT, -1, 26, col)
		var cw := fnt.get_string_size(caption, HORIZONTAL_ALIGNMENT_LEFT, -1, 12).x
		c.draw_string(fnt, Vector2(75 - cw * 0.5, 146), caption,
			HORIZONTAL_ALIGNMENT_LEFT, -1, 12, DIM)
	)
	return c


## A labelled bar, for the second-most-important number on a screen.
static func bar(caption: String, frac: float, col: Color) -> Control:
	var c := Control.new()
	c.custom_minimum_size = Vector2(PANEL_W - 20, 34)
	var v := clampf(frac, 0.0, 1.0)
	c.draw.connect(func() -> void:
		var fnt := ThemeDB.fallback_font
		c.draw_string(fnt, Vector2(0, 12), caption, HORIZONTAL_ALIGNMENT_LEFT,
			-1, 12, DIM)
		var pct := "%d%%" % roundi(v * 100.0)
		var w := fnt.get_string_size(pct, HORIZONTAL_ALIGNMENT_LEFT, -1, 12).x
		c.draw_string(fnt, Vector2(c.size.x - w, 12), pct, HORIZONTAL_ALIGNMENT_LEFT,
			-1, 12, col)
		var track := Rect2(0, 20, c.size.x, 10)
		c.draw_rect(track, Color(1, 1, 1, 0.10))
		c.draw_rect(Rect2(0, 20, c.size.x * v, 10), col)
	)
	return c


## The one sentence at the bottom telling you what to do about it.
static func note(text: String) -> Control:
	var l := Label.new()
	l.text = text
	l.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
	l.custom_minimum_size = Vector2(PANEL_W - 20, 0)
	l.add_theme_font_size_override("font_size", 13)
	l.modulate = Color(1, 0.87, 0.70, 0.85)
	return l


static func _hms(seconds: float) -> String:
	var s := int(maxf(seconds, 0.0))
	if s >= 3600:
		return "%dh %02dm" % [s / 3600, (s % 3600) / 60]
	return "%dm %02ds" % [s / 60, s % 60]
