// Display-space monochrome grain, kept sharp by running after anti-aliasing.
uniform vec3 u_grain; // intensity, pixel size, bounded animation phase

uint grainHash(uint value) {
    value ^= value >> 16u;
    value *= 0x7feb352du;
    value ^= value >> 15u;
    value *= 0x846ca68bu;
    return value ^ (value >> 16u);
}

void fragment() {
    COLOR = FetchColor(PIXCOORD);
    uvec2 pixel = uvec2(floor(vec2(PIXCOORD) / u_grain.y));
    uint seed = pixel.x * 1973u + pixel.y * 9277u + uint(u_grain.z) * 26699u;
    // Triangular, zero-mean noise has fewer harsh speckles than uniform noise.
    float a = float(grainHash(seed) & 65535u) / 65535.0;
    float b = float(grainHash(seed + 104729u) & 65535u) / 65535.0;
    float noise = (a + b - 1.0) * 0.5;
    float luminance = dot(COLOR.rgb, vec3(0.2126, 0.7152, 0.0722));
    float response = 0.35 + 0.65 * (1.0 - abs(2.0 * luminance - 1.0));
    COLOR.rgb = clamp(COLOR.rgb + vec3(noise * u_grain.x * response), 0.0, 1.0);
}
