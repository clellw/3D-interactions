shader_type spatial;
#include "res://assets/materials/blender_voronoi.gdshaderinc"

// Blender "Powder Coated Metal" group. Values are scene-linear.
uniform vec3 color_1 = vec3(0.318555, 0.318555, 0.318555);
uniform vec3 color_2 = vec3(0.0, 0.0, 0.0);
uniform vec3 reflection_color = vec3(0.123227, 0.123227, 0.123227);
uniform float reflection_blend = 0.4295; // RGB Curves output for Reflection Factor 0.6
uniform float global_scale = 1.0;
uniform vec3 aspect_ratio = vec3(1.0, 1.0, 1.0);
uniform float roughness_value = 0.25;
uniform float falloff_strength = 0.2;
uniform float bump_strength = 0.575;
uniform float bump_distance = 0.01;
uniform float flake_mix = 0.4; // Mix Shader factor (principled 2 = black metal flakes)

varying vec3 obj_pos;

void vertex() {
	// Blender "Object" coordinates (Z-up) from Godot local space (Y-up).
	obj_pos = vec3(VERTEX.x, -VERTEX.z, VERTEX.y);
}

void fragment() {
	vec3 n0 = normalize(NORMAL);
	// Mapping Ver. 4: only the scale is non-identity
	vec3 p = obj_pos * global_scale * aspect_ratio;

	// --- Principled 1 (metallic 0.825): Voronoi smooth F1, scale 4 on p * 100
	VoronoiResult va = voronoi_smooth_f1(p * 100.0, 4.0, 1.0, 1.0);
	float rough1 = clamp(va.dist / 0.71818182, 0.0, 1.0); // Colour Ramp 0 -> 0.71818
	vec3 base1 = max(mix(color_1, color_2, va.dist), vec3(0.0)); // Mix, factor not clamped
	float tm = clamp(va.dist, 0.0, 1.0);
	float height = mix(1.0, 0.95, tm * tm * (3.0 - 2.0 * tm)); // Map Range (smoothstep) 1 -> 0.95
	vec3 n1 = bump(bump_strength, bump_distance, height, NORMAL, VERTEX);

	// --- Principled 2 (metallic 1): flakes
	VoronoiResult vb = voronoi_smooth_f1(p, 500.0, 1.0, 1.0);
	float w = white_noise_3d(vb.pos);
	float flake = (abs(w) <= 0.1) ? 1.0 : 0.0; // Math Compare (epsilon 0.1)
	float rough2 = mix(0.46, 0.16, flake); // Map Range.001
	vec3 flake_off = (VIEW_MATRIX * vec4(0.29 * (vb.color - 0.5) * w, 0.0)).xyz;
	vec3 n2 = normalize(n0 + flake_off);

	// --- Mix Shader
	vec3 alb = mix(base1, color_2, flake_mix);
	float met = mix(0.825, 1.0, flake_mix);
	float rgh = mix(rough1, rough2, flake_mix);
	vec3 nrm = normalize(mix(n1, n2, flake_mix));

	// --- Micro Roughness: Fresnel (IOR 1.45) lowers roughness at grazing angles
	float fres_m = fresnel_node(1.45, n0, VIEW, FRONT_FACING);
	float micro = clamp(mix(roughness_value, roughness_value * (1.0 - falloff_strength), fres_m), 0.0, 1.0);

	// --- Reflection.001: Glossy layer weighted by a Layer Weight fresnel
	vec3 n_fres = normalize(mix(n0, VIEW, micro * micro));
	float fres_g = layer_weight_fresnel(reflection_blend, n_fres, VIEW, FRONT_FACING);

	ALBEDO = mix(alb, reflection_color, fres_g);
	METALLIC = mix(met, 1.0, fres_g);
	ROUGHNESS = mix(rgh, micro, fres_g);
	NORMAL = nrm;
}