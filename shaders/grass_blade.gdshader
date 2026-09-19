shader_type spatial;
// Ground cover: two quads crossed in an X per cell, with the blades cut out of
// them here. Drawn on its OWN mesh surface with its own material, deliberately
// NOT appended into the terrain surface -- doing that corrupted that surface and
// stopped whole chunks rendering.
// ambient_light_disabled and a custom light(): grass has to be lit by exactly
// the same rules as the ground it stands on. Left on the renderer's default
// lighting it caught full ambient while the terrain beside it was gated on
// skylight, so a tuft glowed pale against dark soil -- two different worlds.
render_mode cull_disabled, diffuse_burley, ambient_light_disabled;

uniform vec3 ambient_color = vec3(0.45, 0.55, 0.75);
uniform float ambient_energy = 0.3;

// Blades are cut on a TEXEL GRID, not tapered smoothly. Nothing else in this
// game has a diagonal edge in it: the terrain is cubes, the ore lumps are cubes,
// the crack overlay works in cells. Smooth triangles read as imported from a
// different game. Whole texels do not.
const float TEX = 8.0;

varying float v_across;   // 0..1 across the quad
varying float v_up;       // 0 at the root, 1 at the top of the quad
varying vec3 v_tint;
varying float v_sky;    // 0..1 daylight reaching this cell, as the terrain measures it

void vertex() {
	// Both coordinates arrive PER VERTEX (see Chunk._emit_grass). Deriving them
	// from world position does not work: a coordinate out here is ~1300 and a
	// 32-bit float has no resolution left for a pattern this fine.
	v_across = UV.x;
	v_up = UV.y;
	v_tint = COLOR.rgb;
	v_sky = COLOR.a;
}

float hash21(vec2 p) {
	vec3 q = fract(vec3(p.xyx) * 0.1031);
	q += dot(q, q.yzx + 33.33);
	return fract((q.x + q.y) * q.z);
}

void fragment() {
	float gx = floor(clamp(v_across, 0.0, 0.999) * TEX);
	float gy = floor(clamp(v_up, 0.0, 0.999) * TEX);

	// Roughly two thirds of the columns carry a blade, so a tuft has gaps in it
	// rather than being a solid wall of green.
	if (hash21(vec2(gx, 11.0)) < 0.34) {
		discard;
	}
	// Each blade is a whole number of texels tall, so their tops form a ragged
	// stepped line instead of a row of points.
	float h = 2.0 + floor(hash21(vec2(gx, 3.0)) * 5.0);   // 2-6 texels
	if (gy >= h) {
		discard;
	}
	// One texel narrower for the top third: a blocky taper, still on the grid.
	if (gy >= h - 1.0 && hash21(vec2(gx, 5.0)) < 0.5) {
		discard;
	}

	// Darker at the root, paler at the tip, in the same whole steps.
	float t = gy / max(h - 1.0, 1.0);
	vec3 base = v_tint * (0.78 + t * 0.42);
	float sky = clamp(v_sky, 0.0, 1.0);
	ALBEDO = base;
	// The same three terms the terrain shader uses, with the same constants.
	// Matched to the terrain's dark_floor, and lowered with it: a tuft lit to a
	// different floor than the soil under it is the two-worlds problem this
	// shader exists to avoid.
	EMISSION = base * 0.04 * (1.0 - sky)
		+ base * 0.075 * sky
		+ base * ambient_color * ambient_energy * sky;
	AO = sky;
	ROUGHNESS = 0.95;
	SPECULAR = 0.05;
}


// Sunlight is scaled by how much sky reaches the blade, matching the terrain.
void light() {
	float s = clamp(v_sky, 0.0, 1.0);
	DIFFUSE_LIGHT += clamp(dot(NORMAL, LIGHT), 0.0, 1.0)
		* ATTENUATION * LIGHT_COLOR * ALBEDO * s;
}
