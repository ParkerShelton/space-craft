// What the world looks like with your head under water.
//
// Deliberately little: a gentle wash of the water's hue over the frame, and
// nothing that depends on where on the screen a pixel is. The first version
// wobbled the image, laid caustic ripples over it and darkened the edges -- and
// together those drew visible lines across the view, pushed the colour hard
// toward whatever channel the water was strongest in, and left almost nothing
// readable. Distance is the fog's job (see main.gd); this only says "wet".
shader_type canvas_item;

uniform sampler2D screen_tex : hint_screen_texture, filter_linear_mipmap;
// Already softened on the CPU side: the water's hue at full brightness with its
// saturation capped, so multiplying by it can only tint, never darken much or
// swing the whole picture to one colour.
uniform vec3 water_color : source_color = vec3(0.8, 0.92, 1.0);
// 0..1, eased in and out as the camera crosses the surface.
uniform float strength = 1.0;

void fragment() {
	vec3 c = textureLod(screen_tex, SCREEN_UV, 0.0).rgb;
	COLOR = vec4(mix(c, c * water_color, 0.5 * strength), 1.0);
}
