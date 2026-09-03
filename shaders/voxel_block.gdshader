shader_type spatial;
// CULL_DISABLED is deliberate and pairs with backface_collision on the chunk's
// ConcavePolygonShape3D -- together they make rendering AND collision correct
// regardless of triangle winding. Do not "fix" this to cull backfaces.
render_mode cull_disabled, diffuse_burley;

// Procedural, world-space block texturing.
//
// The terrain is greedy-meshed, so a single quad can span any number of blocks
// and has no meaningful UV layout. Deriving the pattern from WORLD POSITION
// instead of UVs sidesteps that entirely: it tiles seamlessly across chunk
// borders, looks identical whether a run of grass was merged into one quad or
// twenty, and costs no texture memory. UV is used only to carry the block id.

uniform float world_seed = 0.0;      // shifts every pattern, so worlds differ
uniform float grass_id = 3.0;        // Blocks.GRASS
uniform float texture_strength = 1.0; // global dial, 0 = flat colours again

varying vec3 v_world;
varying float v_block;
varying vec3 v_normal_os;

float hash13(vec3 p) {
	p = fract(p * 0.1031);
	p += dot(p, p.zyx + 31.32);
	return fract((p.x + p.y) * p.z);
}

// Value noise: cheap, and enough for surface mottling under GL Compatibility.
float vnoise(vec3 p) {
	vec3 i = floor(p);
	vec3 f = fract(p);
	f = f * f * (3.0 - 2.0 * f);
	float n000 = hash13(i + vec3(0.0, 0.0, 0.0));
	float n100 = hash13(i + vec3(1.0, 0.0, 0.0));
	float n010 = hash13(i + vec3(0.0, 1.0, 0.0));
	float n110 = hash13(i + vec3(1.0, 1.0, 0.0));
	float n001 = hash13(i + vec3(0.0, 0.0, 1.0));
	float n101 = hash13(i + vec3(1.0, 0.0, 1.0));
	float n011 = hash13(i + vec3(0.0, 1.0, 1.0));
	float n111 = hash13(i + vec3(1.0, 1.0, 1.0));
	return mix(
		mix(mix(n000, n100, f.x), mix(n010, n110, f.x), f.y),
		mix(mix(n001, n101, f.x), mix(n011, n111, f.x), f.y),
		f.z);
}

float fbm(vec3 p) {
	float a = 0.5;
	float s = 0.0;
	for (int i = 0; i < 3; i++) {
		s += vnoise(p) * a;
		p *= 2.03;
		a *= 0.5;
	}
	return s;
}

void vertex() {
	v_world = (MODEL_MATRIX * vec4(VERTEX, 1.0)).xyz;
	v_block = UV.x;
	v_normal_os = NORMAL;
}

void fragment() {
	// The vertex colour already carries the block's own colour AND the baked
	// per-face directional shading, so it stays the base everything modulates.
	vec3 base = COLOR.rgb;
	vec3 wp = v_world + vec3(world_seed);

	// Per-voxel tint break-up: one value per block cell, so a big merged quad
	// stops reading as a single flat slab of colour.
	float cell = hash13(floor(wp) + 0.5);
	float tint = mix(0.94, 1.06, cell);

	if (abs(v_block - grass_id) < 0.5) {
		// Grass: coarse patchiness plus a finer clumping, and a faint
		// yellow-green shift in the sparser areas so it doesn't read as one
		// uniform green. Blades are far below voxel scale, so this aims for
		// "varied ground cover" rather than individual blades.
		float patch = fbm(wp * 0.35);
		float clump = fbm(wp * 1.7);
		float m = clamp(patch * 0.65 + clump * 0.35, 0.0, 1.0);
		vec3 lush = base * 0.88;
		vec3 dry = clamp(base * vec3(1.28, 1.16, 0.72), 0.0, 1.0);
		vec3 grass = mix(lush, dry, smoothstep(0.35, 0.72, m));
		// Speckle: a few bright/dark flecks to break up flat lighting.
		float fleck = hash13(floor(wp * 4.0) + 11.0);
		grass *= mix(0.93, 1.08, step(0.82, fleck));
		base = mix(base, grass, texture_strength);
	} else {
		base *= mix(1.0, tint, texture_strength);
	}

	ALBEDO = base;
	ROUGHNESS = 0.85;
	METALLIC = 0.0;
}
