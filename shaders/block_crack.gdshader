shader_type spatial;
// Drawn as a thin shell just outside the block being mined, so it must not
// cull anything and must not write depth (it sits coplanar with the surface).
render_mode cull_disabled, unshaded, depth_draw_never, blend_mix;

// Progressive break-up for the block under the pickaxe.
//
// Matches the world's texel art style rather than fighting it: the same cell
// grid the terrain shader uses, with cells going dark in a stable order as
// mining progresses. That reads as a block cracking apart without needing a
// single texture asset, and it works on any shape -- the mesh it is drawn on
// comes from Chunk.shape_boxes, so slabs and stairs crack in their own shape.

uniform float progress = 0.0;   // 0 = untouched, 1 = about to break
uniform float texels = 8.0;     // must match the terrain shader's grid

varying vec3 v_world;
varying vec3 v_normal;

float hash21(vec2 p) {
	vec3 q = fract(vec3(p.xyx) * 0.1031);
	q += dot(q, q.yzx + 33.33);
	return fract((q.x + q.y) * q.z);
}

vec2 face_coord(vec3 wp, vec3 n) {
	vec3 a = abs(n);
	if (a.x > a.y && a.x > a.z) { return wp.zy; }
	if (a.y >= a.x && a.y > a.z) { return wp.xz; }
	return wp.xy;
}

void vertex() {
	v_world = (MODEL_MATRIX * vec4(VERTEX, 1.0)).xyz;
	v_normal = normalize((MODEL_MATRIX * vec4(NORMAL, 0.0)).xyz);
}

void fragment() {
	vec2 fc = face_coord(v_world, normalize(v_normal));

	// Cells, so damage stays blocky and on-style.
	vec2 cell = floor(fc * texels);
	// The cell's own centre, in block units -- everything below is decided per
	// CELL rather than per pixel, which is what keeps the edges hard.
	vec2 cpos = (cell + 0.5) / texels;
	vec2 lp = fract(cpos) - 0.5;

	// Cracks radiate from the middle of the face and grow outward, rather than
	// cells lighting up at random. Scattered cells read as the block
	// dissolving; a few arms spreading from a point read as it splitting.
	float r = length(lp) * 2.0;                 // 0 centre .. ~1 corner
	float ang = atan(lp.y, lp.x);
	float seed = hash21(floor(fc) + 0.5);       // one pattern per block face
	float arms = 3.0 + floor(seed * 3.0);       // 3-5 arms
	float k = (ang / 6.28318 + 0.5) * arms + seed;
	// Distance to the nearest arm, 0 on an arm and 0.5 between arms.
	float da = abs(fract(k) - 0.5);
	// Arms wander slightly instead of being perfectly straight spokes.
	da += (hash21(cell + 11.0) - 0.5) * 0.10;

	// An arm reaches further as mining progresses, so the crack visibly grows.
	float reach = progress * 1.25;
	float on_arm = step(da, 0.16);
	float within = step(r, reach);
	// The centre gives way first, whatever the arms are doing.
	float core = step(r, progress * 0.45);

	float broken = clamp(on_arm * within + core, 0.0, 1.0);

	ALBEDO = vec3(0.02);
	// Fully-formed cracks are near-opaque; a faint wash over the rest of the
	// face late on reads as the whole block being strained.
	ALPHA = broken * 0.8 + smoothstep(0.7, 1.0, progress) * 0.12;
}
