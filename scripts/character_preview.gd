class_name CharacterPreview
extends SubViewportContainer
## You, standing in the inventory -- as Minecraft does it: your figure in your
## skin beside what you are wearing, turning a little to look toward the mouse,
## and spun right round by dragging.
##
## The figure is the same one other players see you as (RemotePlayer), so what
## is shown here is exactly what you look like to them -- and anything worn on
## it later, cosmetics included, shows up here without a second copy of the body
## to keep in step.

var _figure: RemotePlayer
var _cam: Camera3D
var _spin := 0.0          # from dragging
var _look := 0.0          # toward the mouse
var _dragging := false


func _init(box: Vector2i) -> void:
	stretch = true
	custom_minimum_size = Vector2(box)
	mouse_filter = Control.MOUSE_FILTER_STOP
	tooltip_text = "Drag to turn"
	var vp := SubViewport.new()
	vp.size = box
	vp.transparent_bg = true
	vp.own_world_3d = true
	vp.render_target_update_mode = SubViewport.UPDATE_WHEN_VISIBLE
	add_child(vp)
	# The skin editor's lighting: nearly all ambient, so the skin's own colours
	# are what you see, with a little direction to tell the faces apart.
	var env := WorldEnvironment.new()
	var e := Environment.new()
	e.ambient_light_source = Environment.AMBIENT_SOURCE_COLOR
	e.ambient_light_color = Color(1, 1, 1)
	e.ambient_light_energy = 1.0
	env.environment = e
	vp.add_child(env)
	var lamp := DirectionalLight3D.new()
	lamp.rotation_degrees = Vector3(-35, 150, 0)
	lamp.light_energy = 0.2
	vp.add_child(lamp)
	_figure = RemotePlayer.new()
	vp.add_child(_figure)
	_figure.setup(1)
	_figure.show_nameplate(false)
	_cam = Camera3D.new()
	_cam.fov = 30.0
	# The figure faces -Z, so the camera stands on that side looking back at it,
	# a little above centre so the whole body fits with the head near the top.
	_cam.look_at_from_position(Vector3(0.0, 0.25, -4.2), Vector3(0.0, 0.05, 0.0), Vector3.UP)
	vp.add_child(_cam)


## Wear whatever skin is chosen now -- it can have changed in the wardrobe since
## the inventory was last open.
func refresh_skin(img: Image) -> void:
	if img != null:
		_figure.set_skin(img)


func _process(delta: float) -> void:
	if not is_visible_in_tree():
		return
	# Turn to look toward the mouse, a bounded amount either way.
	var m := get_local_mouse_position()
	var off := clampf((m.x - size.x * 0.5) / maxf(size.x, 1.0), -1.5, 1.5)
	_look = lerpf(_look, off * 0.9, clampf(delta * 6.0, 0.0, 1.0))
	# Facing the camera at rest; a positive turn swings its front toward the
	# viewer's right, which is where a mouse to the right is.
	_figure.rotation = Vector3(0.0, _spin + _look, 0.0)


func _gui_input(event: InputEvent) -> void:
	if event is InputEventMouseButton and event.button_index == MOUSE_BUTTON_LEFT:
		_dragging = event.pressed
		accept_event()
	elif event is InputEventMouseMotion and _dragging:
		_spin += event.relative.x * 0.015
		accept_event()
