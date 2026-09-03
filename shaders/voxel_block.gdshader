shader_type spatial;
// CULL_DISABLED is deliberate and pairs with backface_collision on the chunk's
// ConcavePolygonShape3D -- together they make rendering AND collision correct
// regardless of triangle winding. Do not "fix" this to cull backfaces.
render_mode cull_disabled, diffuse_burley;

// Procedural, world-space block texturing.
//
// The terrain is greedy-meshed, so a single quad can span any number of blocks
// and has no meaningful UV layout. Deriving every pattern from WORLD POSITION
// sidesteps that: it tiles seamlessly across chunk borders, looks identical
// whether a run of blocks merged into one quad or twenty, and costs no texture
// memory. UV carries only the block id.
//
// Each material gets its own STRUCTURE rather than one noise recoloured --
// wood is anisotropic grain, dirt is granular, leaves are clumped with real
// holes. All of it is seeded per planet, so no two worlds share a tree.

uniform float world_seed = 0.0;
uniform vec3 planet_center = vec3(0.0);
uniform float texture_strength = 1.0; // global dial, 0 = flat colours again
uniform float leaf_cutout = 1.0;      // 0 disables leaf alpha holes (diagnostic)

// Block id ranges, set from Blocks so they can't drift out of sync.
uniform float grass_id = 3.0;
uniform float dirt_id = 2.0;
uniform float wood_lo = 13.0;
uniform float wood_hi = 15.0;
uniform float leaf_lo = 16.0;
uniform float leaf_hi = 27.0;

varying vec3 v_world;
varying float v_block;
varying vec3 v_normal;

float hash13(vec3 p) {
	p = fract(p * 0.1031);
	p += dot(p, p.zyx + 31.32);
	return fract((p.x + p.y) * p.z);
}

float vnoise(vec3 p) {
	vec3 i = floor(p);
	vec3 f = fract(p);
	f = f * f * (3.0 - 2.0 * f);
	float n000 = hash13(i);
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

float fbm(vec3 p, int octaves) {
	float a = 0.5;
	float s = 0.0;
	for (int i = 0; i < 4; i++) {
		if (i >= octaves) { break; }
		s += vnoise(p) * a;
		p *= 2.07;
		a *= 0.5;
	}
	return s;
}

void vertex() {
	v_world = (MODEL_MATRIX * vec4(VERTEX, 1.0)).xyz;
	// Ids arrive scaled into 0..1 (see Chunk.ID_SCALE) to survive vertex
	// attribute compression; scale back out and snap to the exact integer.
	v_block = floor(UV.x * 64.0 + 0.5);
	v_normal = normalize((MODEL_MATRIX * vec4(NORMAL, 0.0)).xyz);
}

void fragment() {
	// The vertex colour already carries the block's own colour AND the baked
	// per-face directional shading, so it stays the base everything modulates.
	vec3 base = COLOR.rgb;
	vec3 wp = v_world + vec3(world_seed * 7.3, world_seed * 3.1, world_seed * 11.7);
	float id = v_block;
	float alpha = 1.0;

	// "Up" at this point on the planet. Wood grain has to run along the trunk,
	// and trunks grow along the local up, not along world Y -- on a spherical
	// world those are the same thing only near one pole.
	vec3 up = normalize(v_world - planet_center);

	if (abs(id - grass_id) < 0.5) {
		// GRASS: broad patches, finer clumping, and a sub-block speckle so it
		// doesn't read as one-square-per-block.
		float patch = fbm(wp * 0.5, 2);
		float clump = fbm(wp * 2.6, 3);
		float fine = fbm(wp * 11.0, 2);
		float m = clamp(patch * 0.45 + clump * 0.4 + fine * 0.15, 0.0, 1.0);
		vec3 lush = base * 0.86;
		vec3 dry = clamp(base * vec3(1.30, 1.17, 0.70), 0.0, 1.0);
		vec3 g = mix(lush, dry, smoothstep(0.33, 0.72, m));
		g *= 0.96 + fine * 0.10;
		base = mix(base, g, texture_strength);

	} else if (abs(id - dirt_id) < 0.5) {
		// DIRT: granular rather than patchy -- lots of small high-contrast
		// grains, a few larger clods, and scattered dark pebbles.
		float grain = fbm(wp * 12.0, 2);
		float clod = fbm(wp * 3.0, 3);
		float peb = hash13(floor(wp * 6.0));
		vec3 d = base * (0.92 + grain * 0.18);
		d = mix(d, base * 1.06, smoothstep(0.55, 0.8, clod));
		// Grit is a subtle tonal shift, not a blown-out fleck -- at full
		// contrast this read as bright orange blotches rather than soil.
		d *= mix(1.0, 0.86, step(0.94, peb));
		d *= mix(1.0, 1.05, step(0.985, peb));
		base = mix(base, clamp(d, 0.0, 1.0), texture_strength);

	} else if (id >= wood_lo - 0.5 && id <= wood_hi + 0.5) {
		// WOOD: real grain, which means ANISOTROPIC noise -- stretched along the
		// trunk axis so it reads as long fibres, not blobs. Faces looking along
		// the trunk get end grain (rings) instead.
		float along = dot(wp, up);
		vec3 perp = wp - up * along;
		float endness = abs(dot(normalize(v_normal), up));
		// Ring/grain frequency shifts per planet, so one world's trees are
		// visibly a different species from another's.
		float freq = 6.0 + fract(world_seed * 0.37) * 7.0;
		vec3 w;
		if (endness > 0.5) {
			// End grain: concentric rings about each trunk cell's centre.
			float r = length(fract(perp) - 0.5);
			float wob = fbm(perp * 4.0, 2) * 0.35;
			float rings = 0.5 + 0.5 * sin((r + wob) * freq * 6.28318);
			w = base * (0.80 + rings * 0.40);
		} else {
			// Side grain: fibres running the length of the trunk.
			vec3 gp = perp * freq + up * (along * 0.30);
			float fib = fbm(gp, 3);
			float streak = 0.5 + 0.5 * sin((fib * 5.0 + along * 0.7) * 3.14159);
			w = base * (0.78 + streak * 0.44);
			// Occasional darker knot.
			float knot = hash13(floor(wp * 1.3));
			w *= mix(1.0, 0.66, smoothstep(0.965, 1.0, knot));
		}
		base = mix(base, clamp(w, 0.0, 1.0), texture_strength);

	} else if (id >= leaf_lo - 0.5 && id <= leaf_hi + 0.5) {
		// LEAVES: clumped foliage with REAL holes punched through, so a canopy
		// reads as many small leaves rather than a solid painted cube. Uses
		// alpha scissor, which keeps this in the cheap opaque pass and sorts
		// correctly, instead of blended transparency.
		float clump = fbm(wp * 4.0, 3);
		float fine = fbm(wp * 14.0, 2);
		vec3 l = base * (0.86 + fine * 0.28);
		l = mix(l, clamp(base * vec3(1.14, 1.18, 0.86), 0.0, 1.0),
			smoothstep(0.45, 0.8, clump));
		base = mix(base, clamp(l, 0.0, 1.0), texture_strength);
		// Gaps come from the COARSE term only. Driving them off the fine
		// octave punched a hole every few pixels, so a canopy dissolved into
		// speckle instead of reading as clumps of leaves with light between.
		alpha = mix(1.0, smoothstep(0.04, 0.20, clump), texture_strength * leaf_cutout);

	} else {
		// Everything else: sub-block break-up so large merged quads stop
		// reading as flat slabs, without inventing a look for them yet.
		float fine = fbm(wp * 9.0, 2);
		base *= mix(1.0, 0.90 + fine * 0.22, texture_strength);
	}

	ALBEDO = base;
	ALPHA = alpha;
	ALPHA_SCISSOR_THRESHOLD = 0.5;
	ROUGHNESS = 0.85;
	METALLIC = 0.0;
}
