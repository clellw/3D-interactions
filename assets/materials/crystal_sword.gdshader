shader_type spatial;
#include "res://assets/materials/blender_voronoi.gdshaderinc"

// Blender "Procedural Crystal" (group NodeGroup.001). Values are scene-linear.
uniform vec3 base_color = vec3(0.145895, 0.657746, 0.900454);
uniform float transmission_weight = 1.0;
uniform float sheen_weight = 0.483871;
uniform float sheen_roughness = 0.491935;
uniform vec3 sheen_tint = vec3(1.0, 0.162028, 0.834465);
uniform float emissive_intensity = 0.6;
uniform vec3 emission_color = vec3(0.0, 0.454164, 1.0);
uniform float normal_intensity = 0.0;
uniform float roughness_value = 0.4;

// Godot-only: fake refraction through the screen texture.
uniform float refraction_strength = 0.06;
uniform sampler2D screen_tex : hint_screen_texture, repeat_disable, filter_linear_mipmap;

// Bounding box of the mesh in Blender local space (for "Generated" coordinates).
// Values for the "Sphere" object of sword.blend.
uniform vec3 bbox_min = vec3(-1.0, -1.0, -1.0);
uniform vec3 bbox_size = vec3(2.0, 2.0, 2.0);

varying vec3 obj_pos;

void vertex() {
	// Blender "Object" coordinates (Z-up) from Godot local space (Y-up).
	obj_pos = vec3(VERTEX.x, -VERTEX.z, VERTEX.y);
}

void fragment() {
	vec3 gen = (obj_pos - bbox_min) / bbox_size;
	vec3 n0 = normalize(NORMAL);

	// Noise (scale 5, detail 4.2, rough 0.826) -> Colour Ramp.001 (0.41532 -> 0.74597)
	float n = noise_fbm_full(gen * 5.0, 4.2, 0.825926, 2.0, true);
	float t = clamp((n - 0.41532) / (0.74597 - 0.41532), 0.0, 1.0);

	// Base colour: Multiply of base and its HSV-shifted version by t
	vec3 hsv_col = hue_sat_value(base_color, 0.4, 1.3, 0.9);
	vec3 albedo = mix(base_color, base_color * hsv_col, t);

	// Roughness: Mix.001 (multiply 0.25 * 0.45 by t) -> Brightness/Contrast (bright = Roughness, contrast 2)
	float m = mix(0.25, 0.25 * 0.45, t);
	float rough = clamp(brightness_contrast(m, roughness_value, 2.0), 0.0, 1.0);

	// Emission strength: Fresnel(1.5) -> Invert -> Colour Ramp (0.92339 -> 1) - 0.05 * t
	//   -> Brightness/Contrast (bright = Emissive Intensity, contrast 2)
	float fres = fresnel_node(1.5, n0, VIEW, FRONT_FACING);
	float ramp = clamp(((1.0 - fres) - 0.92339) / (1.0 - 0.92339), 0.0, 1.0);
	float emis_strength = brightness_contrast(ramp - 0.05 * t, emissive_intensity, 2.0);

	// Bump (Noise.001 at offset (5,-9,2.8), scale 13.3, detail 4.4, not normalized)
	vec3 nrm = NORMAL;
	if (normal_intensity > 0.0) {
		float h = noise_fbm_full((gen + vec3(5.0, -9.0, 2.8)) * 13.3, 4.4, 0.640741, 2.0, false);
		nrm = bump(normal_intensity, 1.0, h, NORMAL, VERTEX);
	}
	float ndotv = clamp(dot(normalize(nrm), VIEW), 0.0, 1.0);

	// Transmission: blurred, tinted background seen through the surface.
	vec2 refr_uv = SCREEN_UV + nrm.xy * refraction_strength;
	vec3 bg = textureLod(screen_tex, refr_uv, rough * 6.0).rgb;
	vec3 transmitted = bg * albedo * transmission_weight * (1.0 - fres);

	// Sheen approximation (Godot has no sheen lobe): tinted grazing-angle glow.
	vec3 sheen = sheen_tint * sheen_weight * pow(1.0 - ndotv, mix(6.0, 2.0, sheen_roughness));

	ALBEDO = albedo * (1.0 - transmission_weight);
	METALLIC = 0.0;
	ROUGHNESS = rough;
	SPECULAR = 0.5; // IOR 1.5
	NORMAL = nrm;
	EMISSION = transmitted + sheen + emission_color * emis_strength;
}