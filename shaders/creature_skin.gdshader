shader_type spatial;
render_mode diffuse_burley;

// Procedural markings for wildlife.
//
// Every creature is a handful of boxes (see Creature._mk_box), and a flat albedo
// per box made every animal read as the same plastic toy in a different colour.
// These are the markings instead: chosen per species, and laid out in the
// creature's OWN space so a stripe runs continuously from shoulder to flank
// rather than restarting on every box.
//
// pattern: 0 plain, 1 stripes, 2 spots, 3 patches, 4 scales, 5 bands.

uniform vec3 base_color : source_color = vec3(0.6, 0.5, 0.4);
uniform vec3 accent_color : source_color = vec3(0.3, 0.25, 0.2);
uniform int pattern = 0;
uniform float pattern_scale = 1.0;
// Where this box sits on the body, in creature space. Added to the vertex so the
// markings are continuous across separate boxes instead of each limb wearing its
// own copy of the pattern.
uniform vec3 part_origin = vec3(0.0);
// Roughly how tall the animal is, for counter-shading (see below).
uniform float body_height = 1.0;
// Furred animals get a fine directional pile over the top of their markings.
uniform bool furry = false;

varying vec3 v_skin;   // position on the body, scaled for the markings
varying vec3 v_body;   // position on the body, unscaled
// The box's own normal. NORMAL in fragment() is in VIEW space, which slides
// around as the camera moves -- fine for lighting, useless for deciding which
// way is up on the animal or which face of a box we are on.
varying vec3 v_nrm;

float hash13(vec3 p) {
	p = fract(p * 0.1031);
	p += dot(p, p.yzx + 33.33);
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
	return mix(mix(mix(n000, n100, f.x), mix(n010, n110, f.x), f.y),
		mix(mix(n001, n101, f.x), mix(n011, n111, f.x), f.y), f.z);
}

// Two octaves. One octave of noise gives soft even blobs that read as a gradient;
// the second breaks the edges up so a patch looks torn rather than airbrushed.
float fbm(vec3 p) {
	return vnoise(p) * 0.65 + vnoise(p * 2.7 + 11.3) * 0.35;
}

void vertex() {
	v_body = part_origin + VERTEX;
	v_skin = v_body * pattern_scale;
	v_nrm = normalize(NORMAL);
}

void fragment() {
	vec3 p = v_skin;
	float m = 0.0;   // 0 = base colour, 1 = accent

	if (pattern == 1) {
		// Stripes across the body, wobbled so they are not drafting-table
		// straight, and unevenly spaced so they read as an animal's coat.
		float w = p.z * 3.4 + fbm(p * 1.5) * 2.2;
		float t = abs(fract(w) - 0.5) * 2.0;
		m = smoothstep(0.34, 0.52, t);

	} else if (pattern == 2) {
		// Spots: nearest-cell distance, with the radius varying per cell so they
		// are a scatter of different sizes rather than a polka dot grid.
		vec3 c = floor(p * 2.2);
		float best = 9.0;
		float rad = 0.30;
		for (int dx = -1; dx <= 1; dx++) {
			for (int dy = -1; dy <= 1; dy++) {
				for (int dz = -1; dz <= 1; dz++) {
					vec3 g = c + vec3(float(dx), float(dy), float(dz));
					vec3 jit = vec3(hash13(g), hash13(g + 7.1), hash13(g + 19.3));
					float dd = length((g + jit) - p * 2.2);
					if (dd < best) {
						best = dd;
						rad = 0.17 + hash13(g + 3.7) * 0.26;
					}
				}
			}
		}
		m = 1.0 - smoothstep(rad * 0.75, rad, best);

	} else if (pattern == 3) {
		// Big torn patches, the way a piebald hide breaks up.
		m = smoothstep(0.44, 0.60, fbm(p * 0.85));

	} else if (pattern == 4) {
		// Scales: offset rows of small plates, laid out on the FACE rather than on
		// two fixed world axes. Keyed to x/z alone they came out as proper plates
		// on an animal's back and as smeared stripes down its flanks, because a
		// flank varies vertically and the pattern had no vertical term at all.
		vec3 an = abs(v_nrm);
		vec2 uv;
		if (an.x > an.y && an.x > an.z) {
			uv = vec2(p.z, p.y);
		} else if (an.y >= an.x && an.y > an.z) {
			uv = vec2(p.x, p.z);
		} else {
			uv = vec2(p.x, p.y);
		}
		vec2 q = uv * 5.0;
		q.x += mod(floor(q.y), 2.0) * 0.5;
		vec2 f = fract(q) - 0.5;
		float dd = length(f);
		m = (1.0 - smoothstep(0.24, 0.42, dd)) * 0.7;
		m += (1.0 - smoothstep(0.30, 0.46, dd)) * step(f.y, -0.12) * 0.3;

	} else if (pattern == 5) {
		// Rings around the body, like a banded tail or a segmented flank.
		float r = length(vec2(p.x, p.y)) * 2.0 + p.z * 2.2 + fbm(p * 2.0) * 0.6;
		m = smoothstep(0.42, 0.58, fract(r));
	}

	vec3 col = mix(base_color, accent_color, clamp(m, 0.0, 1.0));

	// Counter-shading: nearly every real animal is paler underneath. It is the
	// single cheapest thing that stops a box reading as a box, because it gives
	// the body a top and a bottom independently of where the sun happens to be.
	float low = clamp(1.0 - (v_body.y / max(body_height, 0.001)), 0.0, 1.0);
	col = mix(col, col * 1.5 + vec3(0.05), pow(low, 2.2) * 0.55);

	if (furry) {
		// A fine directional pile: fibres lie along the body, so the noise is
		// stretched along Z and tight across it. Two scales, because real fur
		// reads as clumps of strands rather than as even velvet.
		float fine = vnoise(v_body * vec3(34.0, 34.0, 9.0));
		float clump = vnoise(v_body * vec3(7.0, 7.0, 3.5));
		float pile = fine * 0.6 + clump * 0.4;
		col *= 0.80 + pile * 0.42;
		// Fur catches light on its tips: a rim along faces pointing up and out.
		col += vec3(0.05) * smoothstep(0.55, 1.0, pile) * clamp(v_nrm.y, 0.0, 1.0);
	} else {
		// A little grain everywhere, so even a plain hide is not a flat slab.
		col *= 1.0 + (vnoise(v_body * 9.0) * 0.12 - 0.06);
	}

	// A touch of ambient occlusion into the underside, so limbs read as attached.
	col *= mix(0.86, 1.0, clamp(v_nrm.y * 0.5 + 0.5, 0.0, 1.0));

	ALBEDO = col;
	ROUGHNESS = furry ? 0.97 : 0.86;
	SPECULAR = furry ? 0.05 : 0.18;
}
