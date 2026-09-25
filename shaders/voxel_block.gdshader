shader_type spatial;
// CULL_DISABLED is deliberate and pairs with backface_collision on the chunk's
// ConcavePolygonShape3D -- together they make rendering AND collision correct
// regardless of triangle winding. Do not "fix" this to cull backfaces.
// ambient_light_disabled: the renderer's ambient is added AFTER the fragment
// shader and ignores light(), so a cave wall kept receiving the sky's colour no
// matter what -- looking up underground showed the sky's own tint washed over
// the rock. Ambient is applied here instead, scaled by how much sky the face
// can actually see.
render_mode cull_disabled, diffuse_burley, ambient_light_disabled;

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

// The environment's ambient, handed over so this shader can apply it itself.
uniform vec3 ambient_color : source_color = vec3(0.4, 0.5, 0.7);
uniform float ambient_energy = 0.3;
// How much of a block's own colour still shows where no daylight reaches and
// nothing is burning. Tuned by eye against a sealed room: at this value you can
// just make out where the floor meets the wall and nothing else, which is
// enough to turn around in and not enough to do anything by. Raise it if caves
// turn out to be unnavigable rather than dark.
uniform float dark_floor = 0.07;

uniform float world_seed = 0.0;
uniform vec3 planet_center = vec3(0.0);
uniform float texture_strength = 1.0; // 0 = flat colours again
uniform float leaf_cutout = 1.0;      // 0 = no holes in leaves
// Per-planet SURFACE STYLE. Seeding the pattern alone left every world with the
// same material: same cell size, same number of steps, same contrast. These let
// one planet be a fine even wash and the next a coarse two-tone mottle.
uniform float ground_grain = 1.0;
uniform float ground_levels = 4.0;
uniform float ground_contrast = 1.0;
uniform float rock_grain = 1.0;
uniform float rock_contrast = 1.0;
uniform float leaf_holes = 1.0;       // per-planet gappiness, 0 = solid canopy
uniform float leaf_grain = 1.0;       // per-planet foliage cell size
uniform float texels = 8.0;           // cells per block edge -- the "resolution"

// Block id ranges, set from Blocks so they can't drift out of sync.
uniform float grass_id = 3.0;
uniform float dirt_id = 2.0;
uniform float wood_lo = 13.0;
uniform float wood_hi = 15.0;
uniform float plank_lo = 104.0;
uniform float plank_hi = 106.0;
uniform float leaf_lo = 16.0;
uniform float leaf_hi = 27.0;
uniform float rock_id = 1.0;
// Worked metal: hull plate and the alloy cut from it. Plate is the one material
// in the game that is MANUFACTURED, and speckling it like stone made a ship
// look like it had been carved out of a cliff.
uniform float metal_id = 6.0;
uniform float alloy_id = 60.0;
// How many panels a block face is divided into, and how dark the seam between
// them runs.
uniform float metal_panels = 2.0;
uniform float metal_seam = 0.26;
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
// A campfire's flames are their own geometry (see Chunk.build_mesh_data), drawn
// with the campfire's id so they can burn rather than sit there as orange boxes.
uniform float flame_id = 111.0;

varying vec3 v_world;
varying float v_block;
varying vec3 v_normal;
varying float v_shade;   // baked face shading, so ore chunks light like the face
varying float v_log_axis; // a log's trunk axis (0=X,1=Y,2=Z); 3 = not a log
varying float v_block_light; // 0..1 torch light reaching this face, baked by the mesher
varying float v_sky;         // 0..1 daylight reaching this face, baked by the mesher

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
	v_block_light = UV2.y;
	// Opaque terrain has no use for vertex alpha, so it carries daylight reach.
	v_sky = COLOR.a;
}

// Sunlight is scaled by how much sky reaches the face. Dimming ALBEDO instead
// only makes a lit surface darker -- the sun still falls on it, so a cave was
// bright grey at noon and near black at midnight, tracking the day/night cycle
// exactly like the open surface. Gating the LIGHT is what makes underground
// independent of the time of day.
void light() {
	float s = clamp(v_sky, 0.0, 1.0);
	DIFFUSE_LIGHT += clamp(dot(NORMAL, LIGHT), 0.0, 1.0)
		* ATTENUATION * LIGHT_COLOR * ALBEDO * s;
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
	// Set by the metal branch. Everything else in this world is matte.
	float metalish = 0.0;

	vec2 gcell = floor(fc * texels * ground_grain)
		+ vec2(world_seed * 13.7, world_seed * 7.1);
	float gh = hash21(gcell);

	if (abs(id - grass_id) < 0.5) {
		// GRASS: mostly even, with a few darker and a few brighter cells --
		// enough to break the slab up without looking like static. How even,
		// and at what scale, is this planet's own.
		shade = 1.0 + (quantize(gh, ground_levels) - 0.5) * 0.20 * ground_contrast;

	} else if (abs(id - dirt_id) < 0.5) {
		// DIRT: coarser and grittier, with the occasional near-black cell
		// standing in for a pebble.
		shade = 1.0 + (quantize(gh, ground_levels + 1.0) - 0.5) * 0.26 * ground_contrast;
		shade *= (gh > 0.94) ? 0.78 : 1.0;

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
		// The radial direction must be SNAPPED to an axis. Using it raw makes the
		// grain vanish: `up` would be derived from v_world itself, so v_world is
		// parallel to it by construction and `perp` below collapses to zero --
		// every texel lands in the same band and the bark renders dead flat.
		// Snapping (the same rule as Planet._axis_of) keeps trunks grained on
		// every face of the sphere.
		vec3 rad = normalize(v_world - planet_center);
		vec3 ra = abs(rad);
		vec3 up = (ra.x > ra.y && ra.x > ra.z)
			? vec3(sign(rad.x), 0.0, 0.0)
			: ((ra.y >= ra.z) ? vec3(0.0, sign(rad.y), 0.0) : vec3(0.0, 0.0, sign(rad.z)));
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
			// Measured ACROSS this face -- the direction on it at right angles
			// to the trunk. It used to be a fixed diagonal in the horizontal
			// plane, which only varies across the sides of an upright trunk: a
			// log lying along X or Z, or a trunk standing on four of a cube
			// world's six faces, had two sides with nothing to stripe by and
			// rendered them flat.
			float band = floor(dot(v_world, cross(n, up)) * bands * 2.0);
			shade = 0.82 + quantize(fract(band * 0.37), 3.0) * 0.24;
			// Only a light darkening: the faces already carry baked
			// directional shading, and doubling down on it crushed the
			// bark to near-black in anything but full sun.
			base *= 0.90;
		}
		shade *= 0.97 + h * 0.06;   // faint per-cell break-up on top

	} else if (id >= plank_lo - 0.5 && id <= plank_hi + 0.5) {
		// PLANKS: sawn boards, so the pattern is LONG STRIPES with a dark seam
		// between them, not the log's rings and bark. Boards run along the same
		// face axis everywhere, which is what makes a plank wall read as
		// floorboards instead of a flat panel.
		vec2 tc = fc * texels;
		float board = floor(tc.y / 3.0);          // a board every three texels
		float seam = fract(tc.y / 3.0);
		shade = 0.90 + quantize(hash21(vec2(board, 7.0)), 3.0) * 0.16;
		// Grain along the length of each board, keyed to the board so two
		// neighbours never share a pattern.
		shade *= 0.97 + quantize(hash21(vec2(floor(tc.x), board)), 3.0) * 0.06;
		if (seam < 0.12) {
			shade *= 0.80;                        // the gap between boards
		}

	} else if (id >= leaf_lo - 0.5 && id <= leaf_hi + 0.5) {
		// LEAVES: chunky cells with hard-edged holes punched on the SAME grid,
		// so gaps look like missing pixels rather than smooth erosion. Alpha
		// scissor keeps this in the cheap opaque pass and sorts correctly.
		// Foliage cells are sized per planet, so one world has fine speckled
		// fronds and another broad flat pads.
		vec2 lcell = floor(fc * texels * leaf_grain) + vec2(world_seed * 3.1, world_seed * 5.9);
		float lh = hash21(lcell);
		shade = 0.84 + quantize(lh, 4.0) * 0.28;
		float hole = hash21(lcell + 19.7);
		// Close the holes up with distance. There are no mipmaps on a
		// procedural pattern, so at range a canopy full of one-texel gaps
		// turns into shimmering speckle against the sky -- and every discard
		// costs fill rate. Near the camera, where they actually read as
		// foliage, they stay open.
		float thr = 0.10 * leaf_holes * (1.0 - smoothstep(14.0, 30.0, length(VERTEX)));
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
		float rh = hash21(floor(fc * texels * 0.5 * rock_grain)
			+ vec2(world_seed * 5.0));
		shade = 1.0 + (quantize(rh, 2.0) - 0.5) * 0.05 * rock_contrast;

	} else if (abs(id - flame_id) < 0.5) {
		// Flame. Emissive like any light source, but FLICKERING: a fire that
		// glows at a fixed brightness reads as a lamp. Two offset waves keep the
		// beat from being an obvious pulse, and the world position seeds them so
		// neighbouring fires do not flicker in unison.
		float fseed = v_world.x * 2.3 + v_world.z * 3.7 + v_world.y * 1.1;
		float flick = 0.72
			+ 0.20 * sin(TIME * 8.5 + fseed)
			+ 0.12 * sin(TIME * 19.0 + fseed * 2.7);
		shade = 1.0;
		emit = flick;

	} else if (id >= light_lo - 0.5 && id <= light_hi + 0.5) {
		// A light source is the one thing that should NOT be shaded down by the
		// scene: it makes its own light. Kept flat and emissive so it stays
		// legible in a black cave and still reads as burning in full daylight.
		shade = 1.0;
		emit = 1.0;

	} else if (abs(id - metal_id) < 0.5 || abs(id - alloy_id) < 0.5) {
		// PLATE: panels and seams, not speckle. This is the one material here
		// that somebody MADE, and the giveaway is that it is regular -- a grid
		// of panels with a dark line where they meet and a slight lift toward
		// the middle of each, as though every panel is very lightly domed.
		//
		// The noise is almost nothing. A hull wants to read as manufactured and
		// clean; the same cell hash that makes rock look like rock made a ship
		// look like it had been carved out of a cliff.
		vec2 pf = fract(fc * metal_panels);
		vec2 pd = min(pf, vec2(1.0) - pf);
		float edge = min(pd.x, pd.y);
		float seam = 1.0 - smoothstep(0.0, 0.030, edge);
		float middle = smoothstep(0.030, 0.10, edge);
		float grain = (h - 0.5) * 0.035;
		shade = 1.0 + grain + middle * 0.055 - seam * metal_seam;
		metalish = 1.0;

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
			shade = 1.0 + (quantize(hash21(floor(fc * texels * 0.5 * rock_grain) + 2.0), 2.0)
				- 0.5) * 0.05 * rock_contrast;
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

	// NO grid between blocks. A previous version darkened a hairline wherever two
	// blocks met, to give a flat field of grass some structure -- but two blocks
	// in the same plane are one surface, and drawing a line across it says
	// otherwise. The texel pattern runs straight through a block boundary for the
	// same reason: what makes a step visible is the SIDE face it exposes, which
	// _face_shade sets well apart from a top face, not a line ruled on the top.

	// Underground the surface stops returning daylight, so a cave is dark at
	// noon. Never fully black: torchlight and the mining overlay have to read
	// against it. Torches are EMISSION below and so still work down there.
	float sky = clamp(v_sky, 0.0, 1.0);

	// A block keeps its own colour however dark it gets: dim rock is the same
	// rock, just less of it reaching your eye.
	//
	// This used to slide toward grey as the light went, on the reasoning that
	// real stone in the dark has too little light to see hue by. Whatever that
	// is worth as physics, it looks like the block CHANGING as you walk into a
	// cave, and one thing being two colours is worse than a colour being
	// unrealistic. Anything that dims here now multiplies the colour rather
	// than mixing something else into it, so the hue is the same at every
	// brightness -- see EMISSION below, where every term is `base * <scalar>`.

	ALBEDO = base;
	// Push well past 1.0 so the glow survives tonemapping and reads as a flame
	// rather than a pale cube.
	// Baked block light (see Chunk._compute_block_light). Added as emission so
	// it lights the surface regardless of the renderer's own light handling,
	// and warmed toward flame colour so a torch-lit room reads as firelight
	// rather than just a brighter version of daylight.
	float bl = v_block_light;
	// Warm at BOTH ends. Fading toward white as the light gets stronger put the
	// coldest colour right where the flame is, so a torch sat in a pale grey
	// pool -- the opposite of firelight, which is most orange at its source.
	vec3 lamp = mix(vec3(1.0, 0.58, 0.30), vec3(1.0, 0.76, 0.46), bl);
	// A CONSTANT floor underground, owing nothing to the sun. This is what makes
	// a cave the same darkness at noon and at midnight: it is not sunlight
	// reduced, it is the small amount of light there always is down there.
	// Falloff was SQUARED, which is what made a torch die so quickly a few
	// blocks out: at half reach it was down to a quarter brightness. The flood
	// fill still carries the same distance -- this only changes how much of
	// that distance is bright enough to see by, which is the part that reads as
	// "how far the torch throws".
	EMISSION = base * emit * 2.6 + base * lamp * bl * (0.45 + 0.55 * bl) * 1.9
		// A CONSTANT floor wherever daylight cannot reach, owing nothing to the
		// sun. This is what makes a cave the same darkness at noon and at
		// midnight: not sunlight reduced, but the small amount of light there
		// always is down there.
		//
		// It was 0.145, which is enough to READ a room by. That made a sealed
		// building lit from nowhere -- you could walk into a windowless house
		// and see the far wall, and a cave never needed a torch to be legible,
		// only to be pleasant. Halved, "unlit" still is not a black screen you
		// cannot orient in, but it no longer substitutes for carrying a light.
		+ base * dark_floor * (1.0 - sky)
		// Starlight on anything open to the sky. Invisible against daylight;
		// at night it is the difference between dark and unreadable.
		+ base * 0.13 * sky
		// Ambient, but only where the sky can reach. This is the piece the
		// renderer used to add for us, unconditionally.
		+ base * ambient_color * ambient_energy * sky;
	// Underground, kill the ambient/sky contribution too, or a cave floor still
	// reads as a dim outdoor surface rather than something genuinely unlit.
	// Ambient is sky light too, so it dies underground with everything else.
	AO = sky;
	AO_LIGHT_AFFECT = 1.0;
	// Fully matte. Rock, soil and grass have no sheen, and what specular there
	// was landed on big flat quads as a soft sweep of highlight that slid about
	// as you moved -- which is exactly what a brushed metal panel does.
	// Matte, except for plate. Rock, soil and grass have no sheen -- but a hull
	// with no sheen at all is a grey box, and a little specular is most of what
	// separates worked metal from stone painted grey.
	ROUGHNESS = mix(1.0, 0.42, metalish);
	METALLIC = mix(0.0, 0.55, metalish);
	SPECULAR = mix(0.0, 0.5, metalish);
}
