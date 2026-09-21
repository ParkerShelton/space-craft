// What the world looks like with your head under water.
//
// Drawn over the finished frame rather than baked into every material, because
// being under water is a property of the CAMERA, not of anything it is looking
// at: the same rock is plain from the bank and murky from the lake bed.
//
// The environment fog does the distance -- everything beyond a couple of dozen
// blocks sinks into the water's colour. This does what fog cannot: the gentle
// wobble of light through a moving surface, the colour filter even on things
// right in front of you, the shimmer of caustics, and the dark at the edges.
shader_type canvas_item;

uniform sampler2D screen_tex : hint_screen_texture, filter_linear_mipmap;
// The planet's own water, so an alien sea is an alien colour from inside too.
uniform vec3 water_color : source_color = vec3(0.12, 0.38, 0.52);
// 0..1, eased in and out as the camera crosses the surface.
uniform float strength = 1.0;

void fragment() {
	vec2 uv = SCREEN_UV;
	float t = TIME;

	// Refraction through a surface that never holds still. Small: enough that
	// straight edges waver, not so much that anything is hard to aim at.
	vec2 wob = vec2(sin(uv.y * 17.0 + t * 2.1) + sin(uv.y * 31.0 - t * 1.3) * 0.5,
		cos(uv.x * 13.0 + t * 1.7) + cos(uv.x * 29.0 + t * 1.1) * 0.5) * 0.0028 * strength;
	vec3 c = textureLod(screen_tex, uv + wob, 0.0).rgb;

	// Water keeps its own colour and takes the reds out of everything else. Done
	// as a filter plus a little of the water's own glow, so something bright is
	// still bright down here -- it has just gone blue-green.
	float l = dot(c, vec3(0.299, 0.587, 0.114));
	vec3 filtered = c * mix(vec3(1.0), water_color * 1.9, 0.75);
	vec3 murk = mix(filtered, water_color * (0.25 + l * 1.4), 0.35);

	// Caustics: two crossed ripple patterns, only the peaks kept, strongest
	// toward the top of the view where the light is coming from.
	float ca = sin(uv.x * 38.0 + t * 1.3 + sin(uv.y * 21.0 - t * 0.9) * 1.5)
		* sin(uv.y * 34.0 - t * 1.1 + sin(uv.x * 17.0 + t * 0.7) * 1.5);
	murk += water_color * pow(max(ca, 0.0), 3.0) * 0.35 * (1.1 - uv.y);

	// Darker at the edges, the way a mask or just a lot of water does it.
	float vig = smoothstep(0.95, 0.30, length(uv - vec2(0.5)));
	murk *= mix(0.45, 1.0, vig);

	COLOR = vec4(mix(c, murk, strength), 1.0);
}
