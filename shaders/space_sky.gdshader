shader_type sky;

// Blends between black space (with stars) and a lit atmosphere sky. `atmo` (0..1)
// is driven from code based on how deep in a planet's atmosphere the player is;
// `atmo_up` is the player's local up so the sky gradient looks right anywhere on
// the planet (bright overhead, paler at the horizon).

uniform float star_density = 0.996;
uniform float star_scale = 300.0;
uniform float atmo : hint_range(0.0, 1.0) = 0.0;
uniform vec3 atmo_up = vec3(0.0, 1.0, 0.0);
uniform vec3 sky_color : source_color = vec3(0.45, 0.68, 1.0);
uniform vec3 horizon_color : source_color = vec3(0.75, 0.85, 1.0);

float hash13(vec3 p) {
	p = fract(p * 0.1031);
	p += dot(p, p.yzx + 33.33);
	return fract((p.x + p.y) * p.z);
}

void sky() {
	vec3 d = normalize(EYEDIR);

	// stars, faded out as the atmosphere thickens
	float h = hash13(floor(d * star_scale));
	vec3 space = vec3(step(star_density, h) * (1.0 - atmo));

	// atmosphere: bright overhead (along local up), paler toward the horizon
	float u = clamp(dot(d, normalize(atmo_up)) * 0.5 + 0.5, 0.0, 1.0);
	vec3 skycol = mix(horizon_color, sky_color, u);

	COLOR = mix(space, skycol, atmo);
}
