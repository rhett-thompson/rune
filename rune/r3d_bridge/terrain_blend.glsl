#pragma usage opaque shadow

uniform sampler2D u_grass;
uniform sampler2D u_dirt;
uniform sampler2D u_rock;
uniform vec2 u_uv_scale;
uniform vec2 u_dirt_height;
uniform vec2 u_rock_slope;
uniform vec2 u_noise;

varying vec3 v_terrain_position;
varying vec3 v_terrain_normal;

void vertex() {
    v_terrain_position = POSITION;
    v_terrain_normal = NORMAL;
}

float terrain_hash(vec2 p) {
    // Integer lattice hashing gives identical corner values in adjacent cells.
    // A sine/fract hash can amplify floating-point differences into visible seams.
    uvec2 q = uvec2(ivec2(p));
    uint h = q.x * 374761393u + q.y * 668265263u;
    h = (h ^ (h >> 13u)) * 1274126177u;
    h ^= h >> 16u;
    return float(h & 0x00ffffffu) / 16777215.0;
}

float terrain_noise(vec2 p) {
    vec2 i = floor(p);
    vec2 f = fract(p);
    f = f * f * (3.0 - 2.0 * f);
    return mix(mix(terrain_hash(i), terrain_hash(i + vec2(1, 0)), f.x),
               mix(terrain_hash(i + vec2(0, 1)), terrain_hash(i + vec2(1, 1)), f.x), f.y);
}

// Project on all three axes to avoid stretching the rock on steep faces.
// Local coordinates keep layers attached when terrain entities are transformed.
vec3 terrain_sample(sampler2D layer, vec3 p, vec3 weights) {
    return texture(layer, p.zy).rgb * weights.x
         + texture(layer, p.xz).rgb * weights.y
         + texture(layer, p.xy).rgb * weights.z;
}

void fragment() {
    vec3 normal = normalize(v_terrain_normal);
    vec3 weights = pow(abs(normal), vec3(4.0));
    weights /= max(weights.x + weights.y + weights.z, 0.0001);
    vec3 p = v_terrain_position * vec3(u_uv_scale.x,
                (u_uv_scale.x + u_uv_scale.y) * 0.5, u_uv_scale.y);

    float noise = terrain_noise(v_terrain_position.xz * u_noise.x) * 2.0 - 1.0;
    float detail = terrain_noise(v_terrain_position.xz * u_noise.x * 3.1) * 2.0 - 1.0;
    float variation = (noise * 0.75 + detail * 0.25) * u_noise.y;
    float height = v_terrain_position.y + variation * (u_dirt_height.y - u_dirt_height.x);
    float dirt = 1.0 - smoothstep(u_dirt_height.x, u_dirt_height.y, height);
    float slope = degrees(acos(clamp(normal.y, 0.0, 1.0)));
    float rock = smoothstep(u_rock_slope.x, u_rock_slope.y,
                           slope + variation * (u_rock_slope.y - u_rock_slope.x));

    vec3 grass_color = terrain_sample(u_grass, p, weights);
    vec3 dirt_color = terrain_sample(u_dirt, p, weights);
    vec3 rock_color = terrain_sample(u_rock, p, weights);
    // Custom samplers use raylib's ordinary color textures; decode sRGB before
    // handing the blended albedo to R3D's linear lighting pipeline.
    grass_color = pow(grass_color, vec3(2.2));
    dirt_color = pow(dirt_color, vec3(2.2));
    rock_color = pow(rock_color, vec3(2.2));
    ALBEDO *= mix(mix(grass_color, dirt_color, dirt), rock_color, rock);
}
