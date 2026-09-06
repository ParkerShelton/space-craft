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
// One number per block, set by the miner (see Player._update_crack). In block
// space every block looks alike, so the variety has to be handed in.
uniform float block_seed = 0.0;

// The pattern is laid out in the BLOCK's own space, not the world's. World
// coordinates out here are ~1300 units from the origin, and at that magnitude a
// 32-bit float cannot resolve sixteen texels per block -- the cell grid
// collapsed into noise, which is the graininess this overlay kept showing on a
// real planet while looking perfect on a test quad next to the origin.
varying vec3 v_local;
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
	v_local = VERTEX;
	v_normal = normalize((MODEL_MATRIX * vec4(NORMAL, 0.0)).xyz);
}

void fragment() {
	vec3 n = normalize(v_normal);
	vec2 fc = face_coord(v_local, n);

	// One decision per CELL, and nothing else.
	//
	// This used to build a distance field to line-segment "arms" and threshold it.
	// It looked right in isolation and kept shattering into streaks on a real
	// block, through several rounds of trying to save it. A cell grid with a hash
	// per cell has no such failure mode: there are no derivatives, no distance
	// field, and no way for a value to vary within a cell. Blocks crumble from the
	// point of impact outward, which is what a break reads as.
	vec2 cell = floor(fc * texels);
	vec2 cpos = (cell + 0.5) / texels;
	// +8 keeps fract() clear of zero: the shell is inflated slightly outward, so
	// its local coordinates dip below zero at every edge, and fract() would wrap a
	// negative straight to the far side of the cell.
	vec2 lp = fract(cpos + 8.0) - 0.5;

	// Distance from the middle of the face, 0 at the centre and ~1 at a corner.
	float r = length(lp) * 2.0;
	// Per-cell, and per-FACE: opposite faces project to the same two axes, so
	// without the normal in here every block wore the same break on both sides.
	float h = hash21(cell + vec2(block_seed * 61.7, block_seed * 29.3)
		+ n.xy * 17.0 + vec2(n.z * 23.0));

	// Damage spreads outward: near the centre a cell needs almost no progress to
	// give way, out at the rim it needs nearly all of it. The hash decides the
	// order within each ring, so the break is ragged rather than a growing circle.
	float reach = progress * 1.75 - r * 1.05;
	float broken = step(h, clamp(reach, 0.0, 1.0));
	// A rim one step behind the break: cells that are ALMOST gone. On a dark block
	// in a cave the bright rim is the only part that reads at all.
	float halo = step(h, clamp(reach + 0.30, 0.0, 1.0)) - broken;

	ALBEDO = mix(vec3(0.03), vec3(0.92), halo);
	ALPHA = broken * 0.92 + halo * 0.55;
}
