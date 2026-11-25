shader_type spatial;
#include "res://assets/materials/blender_noise.gdshaderinc"

uniform float brightness : hint_range(0.5, 10.0) = 1.0;

uniform vec3 color_dark = vec3(0.18, 0.10, 0.05);
uniform vec3 color_light = vec3(0.55, 0.34, 0.18);

void fragment() {
	// glTF flips V on export, so restore Blender's V.
	vec2 uv = vec2(UV.x, 1.0 - UV.y);

	// Mapping node: scale (1, -0.02, 1)
	vec3 p = vec3(uv.x, uv.y * -0.02, 0.0);

	// Noise Texture: scale 5, detail 15, roughness 0.7
	float n = noise_fbm(p * 5.0, 15, 0.7, 2.0);

	// Colour Ramp -> Base Color
	float t_col = clamp((n - 0.38636350631713867) / (0.7295457124710083 - 0.38636350631713867), 0.0, 1.0);
	ALBEDO = mix(color_dark, color_light, t_col) * brightness;

	// Colour Ramp.001 -> Roughness (unchanged)
	float t_rough = clamp((n - 0.2940909266471863) / (0.7250001430511475 - 0.2940909266471863), 0.0, 1.0);
	ROUGHNESS = t_rough;
	METALLIC = 0.0;
}