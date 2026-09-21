// What the world looks like with your head under water.
//
// A gentle wash of the water's hue, and a slow warble of the whole picture.
//
// The first version wobbled the frame at high frequency, laid caustic ripples
// over it and darkened the edges -- and drew visible lines across the view.
// Two causes, both avoided here: ripples fine enough to read as stripes, and
// displaced lookups running off the edge of the screen, where the texture
// clamps and smears the border pixel into a streak. The warble is a few long,
// slow waves across the whole view, and the frame is zoomed in by a hair so
// the displacement always has picture to land on.
shader_type canvas_item;

uniform sampler2D screen_tex : hint_screen_texture, filter_linear_mipmap;
// Already softened on the CPU side: the water's hue at full brightness with its
// saturation capped, so multiplying by it can only tint, never darken much or
// swing the whole picture to one colour.
uniform vec3 water_color : source_color = vec3(0.8, 0.92, 1.0);
// 0..1, eased in and out as the camera crosses the surface.
uniform float strength = 1.0;
// How far the warble moves the picture, as a fraction of the screen.
uniform float warble = 0.0045;
// How fast it moves. Faster reads as water; slower read as the screen swaying.
uniform float warble_speed = 1.9;

void fragment() {
	float t = TIME * warble_speed;
	vec2 uv = SCREEN_UV;
	// Zoomed in by more than the warble can move, so no lookup leaves the frame.
	vec2 base = (uv - 0.5) * mix(1.0, 1.0 - warble * 3.0, strength) + 0.5;
	// Long waves -- a handful across the screen -- so it reads as the water
	// moving, not as lines drawn over the view.
	vec2 w = vec2(sin(uv.y * 5.0 + t * 1.5) + 0.5 * sin(uv.y * 9.0 - t * 1.1),
		cos(uv.x * 4.0 + t * 1.2) + 0.5 * cos(uv.x * 7.0 + t * 0.9)) / 1.5;
	vec3 c = textureLod(screen_tex, base + w * warble * strength, 0.0).rgb;
	COLOR = vec4(mix(c, c * water_color, 0.5 * strength), 1.0);
}
