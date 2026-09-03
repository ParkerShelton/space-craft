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
	vec2 cell = floor(fc * texels);
	float h = hash21(cell);

	// Cells break in a fixed order, so damage only ever grows -- it never
	// re-shuffles as progress climbs, which would read as static.
	// Bias slightly toward the cell centre so damage starts in the middle of a
	// face and spreads outward, the way a struck block gives way.
	vec2 local = fract(fc) - 0.5;
	float centre = 1.0 - clamp(length(local) * 1.6, 0.0, 1.0);
	float threshold = h * 0.85 - centre * 0.15;

	float broken = step(threshold, progress);

	// Draw a FRACTURE inside each broken cell rather than filling it in. Solid
	// dark squares read as the block dissolving; short dark segments at varied
	// angles join up across cells into something that reads as cracking.
	vec2 lp = fract(fc * texels) - 0.5;
	float ang = hash21(cell + 3.7) * 3.14159;
	vec2 nrm = vec2(-sin(ang), cos(ang));       // perpendicular to the segment
	float d = abs(dot(lp, nrm));
	float line = 1.0 - smoothstep(0.05, 0.16, d);
	// A second segment across the first, appearing later, so damage visibly
	// deepens rather than just spreading.
	float d2 = abs(dot(lp, vec2(nrm.y, -nrm.x)));
	float line2 = (1.0 - smoothstep(0.04, 0.13, d2)) * smoothstep(0.55, 0.95, progress);

	float crack = clamp(line + line2, 0.0, 1.0) * broken;
	ALBEDO = vec3(0.02);
	// A faint overall darkening on top, so a nearly-broken block reads as
	// damaged even between the fractures.
	ALPHA = crack * 0.85 + broken * progress * 0.12;
}
