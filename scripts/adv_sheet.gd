class_name _AdvSheet
extends Control
## The advancements sheet: one big page you drag around with the mouse.
##
## A ScrollContainer would have done most of this, but not the part that
## matters -- grabbing the page itself and throwing it. A tech tree is a map,
## and a map is something you push around with your hand rather than something
## you steer with two bars at the edges.
##
## It holds one child (`field`) and simply moves it. Everything on the field is
## laid out in page coordinates and never has to know it is being panned.

## How far the page can be pushed past its own edge before it is pulled back.
const SLACK := 60.0
## What is left of a throw after a second.
const GLIDE := 0.06
## Below this it has stopped.
const STILL := 8.0

var field: Control
var content := Vector2.ZERO      # how big the page is

var _at := Vector2.ZERO          # where the page is now
var _vel := Vector2.ZERO
var _dragging := false
var _last := Vector2.ZERO


func _ready() -> void:
	mouse_filter = Control.MOUSE_FILTER_STOP
	set_process(true)


func _gui_input(event: InputEvent) -> void:
	if event is InputEventMouseButton:
		var mb := event as InputEventMouseButton
		if mb.button_index == MOUSE_BUTTON_LEFT:
			_dragging = mb.pressed
			_last = mb.position
			if mb.pressed:
				_vel = Vector2.ZERO
			accept_event()
		elif mb.pressed and mb.button_index == MOUSE_BUTTON_WHEEL_DOWN:
			_vel.y -= 900.0
			accept_event()
		elif mb.pressed and mb.button_index == MOUSE_BUTTON_WHEEL_UP:
			_vel.y += 900.0
			accept_event()
	elif event is InputEventMouseMotion and _dragging:
		var mm := event as InputEventMouseMotion
		_at += mm.position - _last
		# Thrown, not just moved: let go mid-sweep and the page keeps going.
		_vel = mm.relative / maxf(get_process_delta_time(), 0.001)
		_last = mm.position
		_apply()
		accept_event()


func _process(delta: float) -> void:
	if _dragging:
		return
	if _vel.length() > STILL:
		_at += _vel * delta
		_vel *= pow(GLIDE, delta)
	elif _vel != Vector2.ZERO:
		_vel = Vector2.ZERO
	# Always easing back inside its own edges, so a throw that overshoots comes
	# back rather than leaving you looking at nothing.
	var want := _clamped(_at)
	if not want.is_equal_approx(_at):
		_at = _at.lerp(want, clampf(delta * 9.0, 0.0, 1.0))
		_vel *= 0.55
	_apply()


## Where the page is allowed to sit. Anything smaller than the window is
## centred on that axis instead of pinned to a corner.
func _clamped(v: Vector2) -> Vector2:
	var out := v
	for ax in 2:
		var over: float = content[ax] - size[ax]
		if over <= 0.0:
			out[ax] = (size[ax] - content[ax]) * 0.5
		else:
			out[ax] = clampf(v[ax], -over - 8.0, 8.0)
	return out


func _apply() -> void:
	if field == null or not is_instance_valid(field):
		return
	var lim := _clamped(_at)
	# Rubber: past the edge it still moves, but only a fraction as far.
	var soft := _at
	for ax in 2:
		var past: float = _at[ax] - lim[ax]
		if absf(past) > 0.01:
			soft[ax] = lim[ax] + clampf(past, -SLACK, SLACK) * 0.35
	field.position = soft


## Open looking at what you could do next, rather than at the top left corner
## of a page whose interesting part is somewhere in the middle.
func recentre_on_next(at: Dictionary, next: Dictionary) -> void:
	var mid := Vector2.ZERO
	var n := 0
	for id in next:
		if at.has(id):
			mid += at[id] as Vector2
			n += 1
	if n == 0:
		_at = _clamped(Vector2.ZERO)
	else:
		mid /= float(n)
		_at = _clamped(size * 0.5 - mid)
	_vel = Vector2.ZERO
	_apply()
