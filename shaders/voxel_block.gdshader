shader_type spatial;
// CULL_DISABLED is deliberate and pairs with backface_collision on the chunk's
// ConcavePolygonShape3D -- together they make rendering AND collision correct
// regardless of triangle winding. Do not "fix" this to cull backfaces.
render_mode cull_disabled, diffuse_burley;

// Procedural, TEXEL-BASED block texturing.
//
// The look is deliberately chunky rather than realistic: every face is diced
// into a small grid of flat cells, and each cell picks one of a few discrete
// shades. Hard edges and flat colour are what read as "blocky voxel game";
// smooth multi-octave noise reads as photoreal rock and fights the art style.
//
// It is also far cheaper. The previous version ran three or four octaves of
// value noise per fragment (~30 hashes); this runs one or two hashes total, so
// it costs almost nothing even at a large view distance.
//
// Patterns come from WORLD POSITION, never UVs: the terrain is greedy-meshed,
// so one quad can span any number of blocks and has no usable UV layout.
// Texels therefore line up across merged quads and chunk borders for free.
// UV carries only the block id.

uniform float world_seed = 0.0;
uniform vec3 planet_center = vec3(0.0);
uniform float texture_strength = 1.0; // 0 = flat colours again
uniform float leaf_cutout = 1.0;      // 0 = no holes in leaves
uniform float texels = 8.0;           // cells per block edge -- the "resolution"

// Block id ranges, set from Blocks so they can't drift out of sync.
uniform float grass_id = 3.0;
uniform float dirt_id = 2.0;
uniform float wood_lo = 13.0;
uniform float wood_hi = 15.0;
uniform float leaf_lo = 16.0;
uniform float leaf_hi = 27.0;
uniform float rock_id = 1.0;
// Ore BLOCKS are meshed as stone and shade like rock; the ore itself is real
// protruding geometry (see Chunk._emit_ore_chunks) tagged with ore_chunk_id,
// which carries the ore colour in its own vertex colour.
uniform float ore_ids[4];
uniform float ore_chunk_id = 63.0;
// Light-emitting blocks (torch / lamp / ember torch) occupy a contiguous id
// range. They must GLOW rather than merely be a bright colour, or in daylight
// they read as a painted cube and in a dark cave they vanish into the wall.
uniform float light_lo = 91.0;
uniform float light_hi = 93.0;

varying vec3 v_world;
varying float v_block;
varying vec3 v_normal;
varying float v_shade;   // baked face shading, so ore chunks light like the face
varying float v_log_axis; // a log's trunk axis (0=X,1=Y,2=Z); 3 = not a log

float hash21(vec2 p) {
	vec3 q = fract(vec3(p.xyx) * 0.1031);
	q += dot(q, q.yzx + 33.33);
	return fract((q.x + q.y) * q.z);
}

// The two world axes lying in this face's plane, so texels stay square on the
// surface instead of stretching on side faces.
vec2 face_coord(vec3 wp, vec3 n) {
	vec3 a = abs(n);
	if (a.x > a.y && a.x > a.z) { return wp.zy; }
	if (a.y >= a.x && a.y > a.z) { return wp.xz; }
	return wp.xy;
}

// Snap a 0..1 value to `levels` discrete steps -- this is what kills the
// smooth-gradient look and gives flat, poster-like cells.
float quantize(float v, float levels) {
	return floor(v * levels) / max(levels - 1.0, 1.0);
}

void vertex() {
	v_world = (MODEL_MATRIX * vec4(VERTEX, 1.0)).xyz;
	// Ids arrive scaled into 0..1 (see Chunk.ID_SCALE) to stay clear of vertex
	// attribute quantisation; scale back out and snap to the exact integer.
	v_block = floor(UV.x * 64.0 + 0.5);
	v_normal = normalize((MODEL_MATRIX * vec4(NORMAL, 0.0)).xyz);
	v_shade = UV.y;
	v_log_axis = UV2.x;
}

void fragment() {
	// The vertex colour already carries the block's own colour AND the baked
	// per-face directional shading, so it stays the base everything modulates.
	vec3 base = COLOR.rgb;
	float id = v_block;
	float emit = 0.0;

	vec3 n = normalize(v_normal);
	vec2 fc = face_coord(v_world, n);
	// Per-planet offset: the same block looks different world to world.
	vec2 cell = floor(fc * texels) + vec2(world_seed * 13.7, world_seed * 7.1);
	float h = hash21(cell);
	float shade = 1.0;

	if (abs(id - grass_id) < 0.5) {
		// GRASS: mostly even, with a few darker and a few brighter cells --
		// enough to break the slab up without looking like static.
		shade = 0.90 + quantize(h, 4.0) * 0.20;

	} else if (abs(id - dirt_id) < 0.5) {
		// DIRT: coarser and grittier, with the occasional near-black cell
		// standing in for a pebble.
		shade = 0.84 + quantize(h, 5.0) * 0.26;
		shade *= (h > 0.94) ? 0.78 : 1.0;

	} else if (id >= wood_lo - 0.5 && id <= wood_hi + 0.5) {
		// WOOD: the giveaway is BANDS, not speckle. Cells are grouped into
		// stripes running along the trunk (or rings on the cut end), with only
		// slight variation inside a stripe, so it reads as grain rather than
		// noise. Trunks grow along the LOCAL up, which on a sphere is not
		// world Y -- hence planet_center.
		// The trunk axis is recorded when the log is PLACED, so a log lying on
		// its side puts its cut ends on the correct two faces. Deriving it from
		// the planet's up (the old behaviour) is only right for a standing
		// trunk. Falls back to local up for logs from world generation, which
		// carry no axis.
		vec3 up = normalize(v_world - planet_center);
		if (v_log_axis < 2.5) {
			up = (v_log_axis < 0.5) ? vec3(1.0, 0.0, 0.0)
				: ((v_log_axis < 1.5) ? vec3(0.0, 1.0, 0.0) : vec3(0.0, 0.0, 1.0));
		}
		float along = dot(v_world, up);
		vec3 perp = v_world - up * along;
		// Stripe count varies per planet, so worlds get different timber.
		float bands = 3.0 + floor(fract(world_seed * 0.37) * 4.0);
		if (abs(dot(n, up)) > 0.5) {
			// Cut end: concentric rings about each trunk cell's centre, with
			// the exposed inner wood PALER and warmer than the bark.
			float r = length(fract(perp) - 0.5);
			shade = 0.82 + quantize(fract(r * bands * 1.6), 3.0) * 0.26;
			// A RIM of bark is left around the pale core, rather than the whole
			// top going pale -- that border is what gives a cut log depth and
			// reads as the trunk's outside wrapping its inside. Measured in
			// texels off the cell edge, so it scales with the art style.
			vec2 ti = floor(fract(fc) * texels);
			float edge = min(min(ti.x, ti.y),
				min(texels - 1.0 - ti.x, texels - 1.0 - ti.y));
			if (edge < 1.0) {
				base *= 0.90;   // bark, same as the sides
			} else {
				base = clamp(base * vec3(1.75, 1.58, 1.18), 0.0, 1.0);
			}
		} else {
			// Bark: darker than the core, with the grain running lengthways.
			float band = floor(dot(perp, vec3(0.7, 0.0, 0.7)) * bands * 2.0);
			shade = 0.82 + quantize(fract(band * 0.37), 3.0) * 0.24;
			// Only a light darkening: the faces already carry baked
			// directional shading, and doubling down on it crushed the
			// bark to near-black in anything but full sun.
			base *= 0.90;
		}
		shade *= 0.97 + h * 0.06;   // faint per-cell break-up on top

	} else if (id >= leaf_lo - 0.5 && id <= leaf_hi + 0.5) {
		// LEAVES: chunky cells with hard-edged holes punched on the SAME grid,
		// so gaps look like missing pixels rather than smooth erosion. Alpha
		// scissor keeps this in the cheap opaque pass and sorts correctly.
		shade = 0.84 + quantize(h, 4.0) * 0.28;
		float hole = hash21(cell + 19.7);
		// Close the holes up with distance. There are no mipmaps on a
		// procedural pattern, so at range a canopy full of one-texel gaps
		// turns into shimmering speckle against the sky -- and every discard
		// costs fill rate. Near the camera, where they actually read as
		// foliage, they stay open.
		float thr = 0.10 * (1.0 - smoothstep(14.0, 30.0, length(VERTEX)));
		// discard, NOT ALPHA. Writing ALPHA at all makes Godot treat this
		// material as transparent, and transparent surfaces get no omni lights
		// in the Compatibility renderer -- which silently meant torches lit
		// nothing but themselves. discard punches the same holes and leaves the
		// material opaque, so block lighting keeps working.
		if (hole < thr && texture_strength * leaf_cutout > 0.5) {
			discard;
		}

	} else if (abs(id - rock_id) < 0.5) {
		// ROCK: deliberately the smoothest surface in the set. Stone should
		// read as a solid mass, so it gets only two shade steps off a HALF
		// resolution grid -- broad, calm patches rather than per-texel grit.
		float rh = hash21(floor(fc * texels * 0.5) + vec2(world_seed * 5.0));
		shade = 0.965 + quantize(rh, 2.0) * 0.05;

	} else if (id >= light_lo - 0.5 && id <= light_hi + 0.5) {
		// A light source is the one thing that should NOT be shaded down by the
		// scene: it makes its own light. Kept flat and emissive so it stays
		// legible in a black cave and still reads as burning in full daylight.
		shade = 1.0;
		emit = 1.0;

	} else {
		// Everything else: gentle cell break-up so large merged quads stop
		// reading as flat slabs, without inventing a look for them yet.
		shade = 0.93 + quantize(h, 3.0) * 0.14;
	}

	// An ore BLOCK is just stone: it is meshed in the rock colour and shades
	// like rock, because the ore itself is real protruding geometry rather
	// than a pattern painted on the face.
	for (int i = 0; i < 4; i++) {
		if (abs(id - ore_ids[i]) < 0.5) {
			shade = 0.965 + quantize(hash21(floor(fc * texels * 0.5) + 2.0), 2.0) * 0.05;
		}
	}
	// The protruding lumps themselves: keep their own (ore) vertex colour, and
	// quantise harder on a finer grid than the surrounding stone so they read
	// as crystalline and catch the eye against a calm wall.
	if (abs(id - ore_chunk_id) < 0.5) {
		float ch = hash21(floor(fc * texels * 1.5) + vec2(5.0, 9.0));
		shade = 0.88 + quantize(ch, 3.0) * 0.24;
	}

	base *= mix(1.0, shade, texture_strength);

	ALBEDO = base;
	// Push well past 1.0 so the glow survives tonemapping and reads as a flame
	// rather than a pale cube.
	EMISSION = base * emit * 2.6;
	ROUGHNESS = 0.85;
	METALLIC = 0.0;
}
