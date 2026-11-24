// Port of Blender's 3D noise (Jenkins hash + Perlin gradient).

uint rot32(uint x, uint k) {
	return (x << k) | (x >> (32u - k));
}

uint hash_uint3(uint kx, uint ky, uint kz) {
	// 0xdeadbeef + (3 << 2) + 13
	uint init = 3735928584u;
	uint a = init + kx;
	uint b = init + ky;
	uint c = init + kz;
	c ^= b; c -= rot32(b, 14u);
	a ^= c; a -= rot32(c, 11u);
	b ^= a; b -= rot32(a, 25u);
	c ^= b; c -= rot32(b, 16u);
	a ^= c; a -= rot32(c, 4u);
	b ^= a; b -= rot32(a, 14u);
	c ^= b; c -= rot32(b, 24u);
	return c;
}

float noise_fade(float t) {
	return t * t * t * (t * (t * 6.0 - 15.0) + 10.0);
}

float noise_grad(uint hash, float x, float y, float z) {
	uint h = hash & 15u;
	float u = h < 8u ? x : y;
	float vt = (h == 12u || h == 14u) ? x : z;
	float v = h < 4u ? y : vt;
	return (((h & 1u) != 0u) ? -u : u) + (((h & 2u) != 0u) ? -v : v);
}

float noise_perlin(vec3 p) {
	vec3 fl = floor(p);
	vec3 f = p - fl;
	ivec3 ip = ivec3(fl);
	uint X = uint(ip.x);
	uint Y = uint(ip.y);
	uint Z = uint(ip.z);
	float u = noise_fade(f.x);
	float v = noise_fade(f.y);
	float w = noise_fade(f.z);

	return mix(
		mix(
			mix(noise_grad(hash_uint3(X, Y, Z), f.x, f.y, f.z),
				noise_grad(hash_uint3(X + 1u, Y, Z), f.x - 1.0, f.y, f.z), u),
			mix(noise_grad(hash_uint3(X, Y + 1u, Z), f.x, f.y - 1.0, f.z),
				noise_grad(hash_uint3(X + 1u, Y + 1u, Z), f.x - 1.0, f.y - 1.0, f.z), u),
			v),
		mix(
			mix(noise_grad(hash_uint3(X, Y, Z + 1u), f.x, f.y, f.z - 1.0),
				noise_grad(hash_uint3(X + 1u, Y, Z + 1u), f.x - 1.0, f.y, f.z - 1.0), u),
			mix(noise_grad(hash_uint3(X, Y + 1u, Z + 1u), f.x, f.y - 1.0, f.z - 1.0),
				noise_grad(hash_uint3(X + 1u, Y + 1u, Z + 1u), f.x - 1.0, f.y - 1.0, f.z - 1.0), u),
			v),
		w);
}

float noise_snoise(vec3 p) {
	return 0.9820 * noise_perlin(p);
}

// Blender Noise Texture node: 3D, fBM, Normalize on, Distortion 0.
// "p" must already be multiplied by the node's Scale.
float noise_fbm(vec3 p, int detail, float roughness, float lacunarity) {
	float fscale = 1.0;
	float amp = 1.0;
	float maxamp = 0.0;
	float sum = 0.0;
	for (int i = 0; i <= detail; i++) {
		sum += noise_snoise(fscale * p) * amp;
		maxamp += amp;
		amp *= roughness;
		fscale *= lacunarity;
	}
	return 0.5 * (sum / maxamp) + 0.5;
}