shader_type spatial;
render_mode diffuse_burley;

// Procedural markings for wildlife.
//
// Every creature in this game is a handful of boxes (see Creature._mk_box), and
// a flat albedo per box made every animal read as the same plastic toy in a
// different colour. These are the markings instead: chosen per species and laid
// out in the creature's OWN space, so a stripe runs continuously from shoulder
// to flank rather than restarting on every box.
//
// pattern: 0 plain, 1 stripes, 2 spots, 3 patches, 4 scales, 5 bands.

uniform vec3 base_color : source_color = vec3(0.6, 0.5, 0.4);
uniform vec3 accent_color : source_color = vec3(0.3, 0.25, 0.2);
uniform int pattern = 0;
uniform float pattern_scale = 1.0;
// Where this box sits on the body, in creature space. Added to the vertex so
// the markings are continuous across separate boxes instead of each limb
// wearing its own copy of the pattern.
uniform vec3 part_origin = vec3(0.0);

varying vec3 v_skin;   // position on the body, in creature space

float hash13(vec3 p) {
	p = fract(p * 0.1031);
	p += dot(p, p.yzx + 33.33);
	return fract((p.x + p.y) * p.z);
}

// Value noise, for markings with a soft irregular edge rather than a hard grid.
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

void vertex() {
	v_skin = (part_origin + VERTEX) * pattern_scale;
}

void fragment() {
	vec3 p = v_skin;
	float m = 0.0;   // 0 = base colour, 1 = accent

	if (pattern == 1) {
		// Stripes across the body, wobbled so they are not drafting-table
		// straight. Along Z, which is the long axis of every body here.
		float w = p.z * 3.4 + vnoise(p * 1.6) * 1.6;
		m = smoothstep(0.42, 0.58, abs(fract(w) - 0.5) * 2.0);

	} else if (pattern == 2) {
		// Spots: nearest-cell distance, so they read as round dabs.
		vec3 c = floor(p * 2.2);
		float best = 9.0;
		for (int dx = -1; dx <= 1; dx++) {
			for (int dy = -1; dy <= 1; dy++) {
				for (int dz = -1; dz <= 1; dz++) {
					vec3 g = c + vec3(float(dx), float(dy), float(dz));
					vec3 jitter = vec3(hash13(g), hash13(g + 7.1), hash13(g + 19.3));
					best = min(best, length((g + jitter) - p * 2.2));
				}
			}
		}
		m = 1.0 - smoothstep(0.22, 0.42, best);

	} else if (pattern == 3) {
		// Big soft patches, the way a piebald hide breaks up.
		m = smoothstep(0.46, 0.62, vnoise(p * 0.9));

	} else if (pattern == 4) {
		// Scales: offset rows of small rounded plates.
		vec2 q = vec2(p.x, p.z) * 5.0;
		q.x += mod(floor(q.y), 2.0) * 0.5;
		vec2 f = fract(q) - 0.5;
		m = 1.0 - smoothstep(0.24, 0.44, length(f));
		m *= 0.75;

	} else if (pattern == 5) {
		// Rings around the body, like a banded tail or a segmented flank.
		float r = length(vec2(p.x, p.y)) * 2.0 + p.z * 2.2;
		m = smoothstep(0.45, 0.55, fract(r));
	}

	// A little grain everywhere, so even a plain animal is not a flat slab.
	float grain = vnoise(p * 7.0) * 0.10 - 0.05;
	vec3 col = mix(base_color, accent_color, clamp(m, 0.0, 1.0)) * (1.0 + grain);

	// A darker underside reads as shading that belongs to the animal rather
	// than to whatever light happens to be on it.
	col *= mix(0.82, 1.0, clamp(NORMAL.y * 0.5 + 0.5, 0.0, 1.0));

	ALBEDO = col;
	ROUGHNESS = 0.88;
	SPECULAR = 0.15;
}
