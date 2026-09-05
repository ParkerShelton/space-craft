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
// Finer than the terrain grid on purpose. Cracks are LINE work: at 8 cells per
// face a line one cell wide is a row of fat dashes, which read as streaky noise
// rather than a break. The blocky look still comes through at 16.
uniform float texels = 16.0;

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

// Distance from a point to a line SEGMENT. Cracks are drawn as segments rather
// than angular wedges: a wedge is fat at the centre and hairline at the rim, so
// every break turned into a blob at the impact point with dashes trailing off it.
float seg_d(vec2 p, vec2 a, vec2 b) {
	vec2 pa = p - a;
	vec2 ba = b - a;
	float h = clamp(dot(pa, ba) / max(dot(ba, ba), 1e-6), 0.0, 1.0);
	return length(pa - ba * h);
}

void vertex() {
	v_world = (MODEL_MATRIX * vec4(VERTEX, 1.0)).xyz;
	v_normal = normalize((MODEL_MATRIX * vec4(NORMAL, 0.0)).xyz);
}

void fragment() {
	vec3 n = normalize(v_normal);
	vec2 fc = face_coord(v_world, n);

	// Cells, so damage stays blocky and on-style. Everything below is decided
	// per CELL (from the cell's own centre) rather than per pixel, which is what
	// keeps the edges hard instead of smoothly antialiased.
	vec2 cell = floor(fc * texels);
	vec2 cpos = (cell + 0.5) / texels;
	vec2 lp = fract(cpos) - 0.5;          // -0.5 .. 0.5 across the face

	// Seeded from the face's own NORMAL as well as its position. Opposite faces
	// project to the same two world axes, so without the normal every block wore
	// the identical crack on both sides of it.
	float seed = hash21(floor(fc) + 0.5 + n.xy * 37.0 + vec2(n.z * 53.0));

	// Each arm is a two-segment polyline from the impact point: one kink gives it
	// a fracture's dog-leg instead of a ruler-straight ray, and arms are placed at
	// their own random angles rather than evenly spaced (even spacing drew a tidy
	// pinwheel -- four arms with a consistent bend make a shape nobody wants).
	float arms = 3.0 + floor(hash21(vec2(seed, 4.0)) * 3.0);   // 3-5
	float d = 99.0;
	for (int i = 0; i < 5; i++) {
		if (float(i) >= arms) { break; }
		float fi = float(i);
		// Arms appear one after another as the block gives way, so the break
		// spreads rather than every line growing in lockstep.
		float birth = fi * 0.13;
		float grow = clamp((progress - birth) / max(1.0 - birth, 0.001), 0.0, 1.0);
		if (grow <= 0.0) { continue; }
		float a0 = hash21(vec2(seed * 31.0, fi)) * 6.28318;
		float len = grow * (0.30 + hash21(vec2(seed * 17.0, fi + 9.0)) * 0.24);
		float bend = (hash21(vec2(seed * 7.0, fi + 3.0)) - 0.5) * 1.2;
		vec2 mid = vec2(cos(a0), sin(a0)) * len * 0.55;
		vec2 tip = mid + vec2(cos(a0 + bend), sin(a0 + bend)) * len * 0.55;
		d = min(d, seg_d(lp, vec2(0.0), mid));
		d = min(d, seg_d(lp, mid, tip));
	}
	// A wobble well under one texel, so the line edge is ragged without the
	// line itself breaking up into scattered cells.
	d += (hash21(cell + 11.0) - 0.5) * (0.5 / texels);

	// Constant width, in texels -- a crack thinner than a texel cannot draw a
	// continuous line on a cell grid, it just quantises into dashes.
	float w = 1.0 / texels;
	// The impact point itself always gives way, and widens as mining goes on.
	float core = 0.04 + progress * 0.05;
	float dark = min(d - w, length(lp) - core);

	float broken = step(dark, 0.0);
	// A dark crack is invisible on a dark block, which is exactly where mining
	// happens most -- caves, night, anywhere the sun does not reach. So the crack
	// is drawn as a dark line with a BRIGHT rim exactly one texel outside it: the
	// line reads against lit rock, the rim reads against black, and neither needs
	// to know what is behind it.
	float halo = step(dark, 1.0 / texels) - broken;

	ALBEDO = mix(vec3(0.02), vec3(0.9), halo);
	// A faint wash over the whole face late on reads as the block being strained.
	ALPHA = broken * 0.9 + halo * 0.5 + smoothstep(0.75, 1.0, progress) * 0.1;
}
