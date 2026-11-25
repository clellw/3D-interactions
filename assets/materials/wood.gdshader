shader_type spatial;
#include "res://assets/materials/blender_noise.gdshaderinc"

void fragment() {
	// glTF flips V on export, so restore Blender's V.
	vec2 uv = vec2(UV.x, 1.0 - UV.y);

	// Mapping node: scale (1, -0.02, 1)
	vec3 p = vec3(uv.x, uv.y * -0.02, 0.0);

	// Noise Texture: scale 5, detail 15, roughness 0.7
	float n = noise_fbm(p * 5.0, 15, 0.7, 2.0);

	// Colour Ramp -> Base Color (linear interpolation, values are scene-linear)
	float t_col = clamp((n - 0.38636350631713867) / (0.7295457124710083 - 0.38636350631713867), 0.0, 1.0);
	ALBEDO = mix(
    vec3(0.08, 0.04, 0.02),
    vec3(0.35, 0.18, 0.10),
    t_col
);
	// Colour Ramp.001 -> Roughness (black -> white)
	float t_rough = clamp((n - 0.2940909266471863) / (0.7250001430511475 - 0.2940909266471863), 0.0, 1.0);
	ROUGHNESS = t_rough;
	METALLIC = 0.0;
}