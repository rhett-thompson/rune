#pragma usage opaque shadow

uniform sampler2D u_grass;
uniform sampler2D u_dirt;
uniform sampler2D u_rock;
uniform vec4 u_grass_color;
uniform vec4 u_dirt_color;
uniform vec4 u_rock_color;
uniform vec4 u_grass_pbr;
uniform vec4 u_dirt_pbr;
uniform vec4 u_rock_pbr;
uniform vec4 u_grass_sampling;
uniform vec4 u_dirt_sampling;
uniform vec4 u_rock_sampling;
uniform vec2 u_uv_scale;
uniform vec2 u_dirt_height;
uniform vec2 u_rock_slope;
uniform vec2 u_noise;

varying vec3 v_terrain_position;
varying vec3 v_terrain_normal;
varying vec3 v_normal_x;
varying vec3 v_normal_y;
varying vec3 v_normal_z;

void vertex() {
    v_terrain_position = POSITION;
    v_terrain_normal = NORMAL;
    v_normal_x = MATRIX_NORMAL * vec3(1, 0, 0);
    v_normal_y = MATRIX_NORMAL * vec3(0, 1, 0);
    v_normal_z = MATRIX_NORMAL * vec3(0, 0, 1);
}

float terrain_hash(vec2 p) {
    uvec2 q = uvec2(ivec2(p));
    uint h = q.x * 374761393u + q.y * 668265263u;
    h = (h ^ (h >> 13u)) * 1274126177u;
    h ^= h >> 16u;
    return float(h & 0x00ffffffu) / 16777215.0;
}

float terrain_noise(vec2 p) {
    vec2 i = floor(p), f = fract(p);
    f = f * f * (3.0 - 2.0 * f);
    return mix(mix(terrain_hash(i), terrain_hash(i + vec2(1, 0)), f.x),
               mix(terrain_hash(i + vec2(0, 1)), terrain_hash(i + vec2(1, 1)), f.x), f.y);
}

vec3 atlas_texel(sampler2D atlas, ivec2 xy, int cell, int size, int lod) {
    xy = (xy % size + size) % size;
    xy.y += cell * size;
    return texelFetch(atlas, xy, lod).rgb;
}

vec3 atlas_level(sampler2D atlas, vec2 uv, int cell, vec4 sampling, int lod) {
    int size = max(1, int(sampling.y) >> lod);
    if (sampling.x == 0.0 || sampling.x == 3.0)
        return atlas_texel(atlas, ivec2(floor(fract(uv) * float(size))), cell, size, lod);
    vec2 p = fract(uv) * float(size) - 0.5;
    ivec2 i = ivec2(floor(p));
    vec2 f = fract(p);
    return mix(mix(atlas_texel(atlas, i, cell, size, lod), atlas_texel(atlas, i + ivec2(1,0), cell, size, lod), f.x),
               mix(atlas_texel(atlas, i + ivec2(0,1), cell, size, lod), atlas_texel(atlas, i + ivec2(1,1), cell, size, lod), f.x), f.y);
}

vec3 atlas_lod(sampler2D atlas, vec2 uv, int cell, vec4 sampling, float lod) {
    // Mips above log2(cell size) merge unrelated channels and must never be read.
    float max_lod = min(sampling.z, log2(sampling.y));
    lod = clamp(lod, 0.0, max_lod);
    if (sampling.x == 0.0) return atlas_level(atlas, uv, cell, sampling, 0);
    if (sampling.x == 1.0 || sampling.x == 3.0)
        return atlas_level(atlas, uv, cell, sampling, int(floor(lod + 0.5)));
    int low = int(floor(lod)), high = min(low + 1, int(max_lod));
    return mix(atlas_level(atlas, uv, cell, sampling, low), atlas_level(atlas, uv, cell, sampling, high), fract(lod));
}

vec3 atlas_sample(sampler2D atlas, vec2 uv, vec2 dx, vec2 dy, int cell, vec4 sampling) {

    float lx = length(dx) * sampling.y, ly = length(dy) * sampling.y;
    float major = max(lx, ly), minor = max(min(lx, ly), 0.0001);
    int taps = int(clamp(ceil(major / minor), 1.0, sampling.w));
    float lod = log2(max(major / float(taps), 0.0001));
    vec2 axis = lx > ly ? dx : dy;
    vec3 result = vec3(0);
    for (int i = 0; i < taps; ++i)
        result += atlas_lod(atlas, uv + axis * ((float(i) + 0.5) / float(taps) - 0.5), cell, sampling, lod);
    return result / float(taps);
}

vec3 projected_map(sampler2D atlas, vec3 p, vec3 dx, vec3 dy, vec3 weights, int cell, vec4 sampling) {
    return atlas_sample(atlas,p.zy,dx.zy,dy.zy,cell,sampling)*weights.x
         + atlas_sample(atlas,p.xz,dx.xz,dy.xz,cell,sampling)*weights.y
         + atlas_sample(atlas,p.xy,dx.xy,dy.xy,cell,sampling)*weights.z;
}

vec2 normal_slope(vec3 encoded, float strength) {
    // RGBA8 flat normals encode XY as 128; remove that quantization bias.
    vec2 xy = (encoded.xy * 255.0 - 128.0) / 127.0;
    float z = max(encoded.z * 2.0 - 1.0, 0.1);
    return xy / z * strength;
}

vec3 projected_gradient(sampler2D atlas, vec3 p, vec3 dx, vec3 dy, vec3 weights, vec4 sampling, float strength) {
    vec2 x = normal_slope(atlas_sample(atlas,p.zy,dx.zy,dy.zy,1,sampling),strength);
    vec2 y = normal_slope(atlas_sample(atlas,p.xz,dx.xz,dy.xz,1,sampling),strength);
    vec2 z = normal_slope(atlas_sample(atlas,p.xy,dx.xy,dy.xy,1,sampling),strength);
    return vec3(0,x.y,x.x)*weights.x + vec3(y.x,0,y.y)*weights.y + vec3(z.x,z.y,0)*weights.z;
}

void fragment() {
    vec3 n = normalize(v_terrain_normal);
    vec3 projections = pow(abs(n),vec3(4.0));
    projections /= max(projections.x+projections.y+projections.z,0.0001);
    vec3 p = v_terrain_position * vec3(u_uv_scale.x,(u_uv_scale.x+u_uv_scale.y)*0.5,u_uv_scale.y);
    vec3 dx = dFdx(p), dy = dFdy(p);
    float variation = ((terrain_noise(v_terrain_position.xz*u_noise.x)*2.0-1.0)*0.75
                    + (terrain_noise(v_terrain_position.xz*u_noise.x*3.1)*2.0-1.0)*0.25)*u_noise.y;
    float height = v_terrain_position.y + variation*(u_dirt_height.y-u_dirt_height.x);
    float dirt = 1.0-smoothstep(u_dirt_height.x,u_dirt_height.y,height);
    float slope = degrees(acos(clamp(n.y,0.0,1.0)));
    float rock = smoothstep(u_rock_slope.x,u_rock_slope.y,slope+variation*(u_rock_slope.y-u_rock_slope.x));
    vec3 blend = vec3((1.0-dirt)*(1.0-rock),dirt*(1.0-rock),rock);

    vec3 grass = pow(projected_map(u_grass,p,dx,dy,projections,0,u_grass_sampling),vec3(2.2))*u_grass_color.rgb;
    vec3 soil = pow(projected_map(u_dirt,p,dx,dy,projections,0,u_dirt_sampling),vec3(2.2))*u_dirt_color.rgb;
    vec3 stone = pow(projected_map(u_rock,p,dx,dy,projections,0,u_rock_sampling),vec3(2.2))*u_rock_color.rgb;
    ALBEDO *= grass*blend.x + soil*blend.y + stone*blend.z;

    vec3 a = projected_map(u_grass,p,dx,dy,projections,2,u_grass_sampling);
    vec3 b = projected_map(u_dirt,p,dx,dy,projections,2,u_dirt_sampling);
    vec3 c = projected_map(u_rock,p,dx,dy,projections,2,u_rock_sampling);
    OCCLUSION = dot(vec3(mix(1.0,a.r,u_grass_pbr.x),mix(1.0,b.r,u_dirt_pbr.x),mix(1.0,c.r,u_rock_pbr.x)),blend);
    ROUGHNESS = dot(vec3(a.g*u_grass_pbr.y,b.g*u_dirt_pbr.y,c.g*u_rock_pbr.y),blend);
    METALNESS = dot(vec3(a.b*u_grass_pbr.z,b.b*u_dirt_pbr.z,c.b*u_rock_pbr.z),blend);
    SPECULAR = dot(vec3(u_grass_color.a,u_dirt_color.a,u_rock_color.a),blend);

    vec3 gradient = projected_gradient(u_grass,p,dx,dy,projections,u_grass_sampling,u_grass_pbr.w)*blend.x
                  + projected_gradient(u_dirt,p,dx,dy,projections,u_dirt_sampling,u_dirt_pbr.w)*blend.y
                  + projected_gradient(u_rock,p,dx,dy,projections,u_rock_sampling,u_rock_pbr.w)*blend.z;
    vec3 local_normal = normalize(n + gradient - n*dot(n,gradient));
    NORMAL = normalize(mat3(v_normal_x,v_normal_y,v_normal_z)*local_normal);
    NORMAL_MAP = vec3(0.5,0.5,1);
}
