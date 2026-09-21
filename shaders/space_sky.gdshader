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
// Day/night. `sun_dir` points FROM the viewer TOWARD the sun, so a sun disc can
// be drawn and the sky brightened around it; `day` is 0 at night, 1 at noon.
uniform vec3 sun_dir = vec3(0.0, 1.0, 0.0);
uniform float day : hint_range(0.0, 1.0) = 1.0;
// Night-sky curtains of light, on worlds that have them (see Weather). 0 = none.
uniform float aurora : hint_range(0.0, 1.0) = 0.0;
uniform vec3 aurora_color : source_color = vec3(0.2, 1.0, 0.55);
uniform vec3 aurora_color2 : source_color = vec3(0.55, 0.35, 1.0);
// How far the viewer is INSIDE the planet. Caves can be wider than the streamed
// chunk radius, and there is nothing behind an unloaded chunk but the skybox --
// so from a big cavern you could see stars and other planets through the rock.
// Underground the sky simply goes black, which is both a fix and the truth.
uniform float underground : hint_range(0.0, 1.0) = 0.0;

float hash13(vec3 p) {
	p = fract(p * 0.1031);
	p += dot(p, p.yzx + 33.33);
	return fract((p.x + p.y) * p.z);
}

void sky() {
	vec3 d = normalize(EYEDIR);

	// Stars are drawn ON TOP of the sky rather than blended away by it. Mixing
	// them out by `atmo` meant that standing on a planet (atmo ~= 1) hid them
	// completely whatever the time of day, so night had no stars at all.
	float h = hash13(floor(d * star_scale));
	float stars = step(star_density, h);
	// Daylight washes them out; the night sky is thin enough to see through.
	float star_vis = 1.0 - atmo * smoothstep(0.12, 0.7, day);

	// atmosphere: bright overhead (along local up), paler toward the horizon
	float u = clamp(dot(d, normalize(atmo_up)) * 0.5 + 0.5, 0.0, 1.0);
	vec3 skycol = mix(horizon_color, sky_color, u);

	// The sun itself: a disc, with a broad glow around it that warms the sky
	// near the horizon at dawn and dusk.
	vec3 sd = normalize(sun_dir);
	float sun_d = dot(d, sd);
	float disc = smoothstep(0.9994, 0.9997, sun_d);
	float glow = pow(max(sun_d, 0.0), 220.0) * 0.5 + pow(max(sun_d, 0.0), 8.0) * 0.12;
	vec3 sun_col = mix(vec3(1.0, 0.55, 0.25), vec3(1.0, 0.96, 0.88), day);

	vec3 sky_lit = skycol + sun_col * glow * atmo;
	COLOR = (sky_lit * atmo + stars * star_vis) * (1.0 - underground);
	// The disc stays visible in space too, where there is no atmosphere.
	COLOR += sun_col * disc;

	// Aurora: a band of light partway up the sky that wanders round the horizon
	// and slowly sways, made of fine vertical rays, its colour shifting toward
	// the second one higher up. Measured around the planet's own up, so it hangs
	// over the right part of the sky anywhere on a sphere.
	if (aurora > 0.001) {
		vec3 up = normalize(atmo_up);
		float el = dot(d, up);
		vec3 t1 = normalize(cross(up, abs(up.y) < 0.9 ? vec3(0.0, 1.0, 0.0) : vec3(1.0, 0.0, 0.0)));
		vec3 t2 = cross(up, t1);
		float az = atan(dot(d, t2), dot(d, t1));
		float t = TIME;
		float wave = sin(az * 3.0 + t * 0.05 + sin(az * 7.0 - t * 0.11) * 0.8);
		float centre = 0.42 + 0.12 * wave;
		float band = exp(-pow((el - centre) / 0.11, 2.0));
		float rays = 0.55 + 0.45 * sin(az * 55.0 + t * 0.35 + sin(az * 11.0 + t * 0.2) * 3.0);
		float shimmer = 0.75 + 0.25 * sin(t * 0.7 + az * 5.0);
		vec3 col = mix(aurora_color, aurora_color2, smoothstep(centre - 0.02, centre + 0.2, el));
		COLOR += col * band * rays * shimmer * aurora * 0.85 * step(0.0, el) * (1.0 - underground);
	}
}
