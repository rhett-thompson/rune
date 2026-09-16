#pragma usage opaque shadow
uniform sampler2D u_layers_a;
uniform sampler2D u_layers_b;
uniform sampler2D u_parameters;
uniform sampler2D u_controls;
uniform vec4 u_terrain;
varying vec3 v_terrain_position;
varying vec3 v_terrain_normal;
varying vec3 v_normal_x;
varying vec3 v_normal_y;
varying vec3 v_normal_z;
void vertex() {
    v_terrain_position = POSITION;
    v_terrain_normal = NORMAL;
    v_normal_x = MATRIX_NORMAL * vec3(1,0,0);
    v_normal_y = MATRIX_NORMAL * vec3(0,1,0);
    v_normal_z = MATRIX_NORMAL * vec3(0,0,1);
}
vec3 atlas_texel(sampler2D atlas, int slot, ivec2 xy, int cell, int size, int lod) {
    xy = (xy % size + size) % size;
    xy.y += cell * size;
    xy.x += slot * size;
    return texelFetch(atlas, xy, lod).rgb;
}

vec3 atlas_level(sampler2D atlas, int slot, vec2 uv, int cell, vec4 sampling, int lod) {
    int size = max(1, int(sampling.y) >> lod);
    if (sampling.x == 0.0 || sampling.x == 3.0)
        return atlas_texel(atlas,slot, ivec2(floor(fract(uv) * float(size))), cell, size, lod);
    vec2 p = fract(uv) * float(size) - 0.5;
    ivec2 i = ivec2(floor(p));
    vec2 f = fract(p);
    return mix(mix(atlas_texel(atlas,slot, i, cell, size, lod), atlas_texel(atlas,slot, i + ivec2(1,0), cell, size, lod), f.x),
               mix(atlas_texel(atlas,slot, i + ivec2(0,1), cell, size, lod), atlas_texel(atlas,slot, i + ivec2(1,1), cell, size, lod), f.x), f.y);
}

vec3 atlas_lod(sampler2D atlas, int slot, vec2 uv, int cell, vec4 sampling, float lod) {
    // Mips above log2(cell size) merge unrelated channels and must never be read.
    float max_lod = min(sampling.z, log2(sampling.y));
    lod = clamp(lod, 0.0, max_lod);
    if (sampling.x == 0.0) return atlas_level(atlas,slot, uv, cell, sampling, 0);
    if (sampling.x == 1.0 || sampling.x == 3.0)
        return atlas_level(atlas,slot, uv, cell, sampling, int(floor(lod + 0.5)));
    int low = int(floor(lod)), high = min(low + 1, int(max_lod));
    return mix(atlas_level(atlas,slot, uv, cell, sampling, low), atlas_level(atlas,slot, uv, cell, sampling, high), fract(lod));
}

vec3 atlas_sample(sampler2D atlas, int slot, vec2 uv, vec2 dx, vec2 dy, int cell, vec4 sampling) {

    float lx = length(dx) * sampling.y, ly = length(dy) * sampling.y;
    float major = max(lx, ly), minor = max(min(lx, ly), 0.0001);
    int taps = int(clamp(ceil(major / minor), 1.0, sampling.w));
    float lod = log2(max(major / float(taps), 0.0001));
    vec2 axis = lx > ly ? dx : dy;
    vec3 result = vec3(0);
    for (int i = 0; i < taps; ++i)
        result += atlas_lod(atlas,slot, uv + axis * ((float(i) + 0.5) / float(taps) - 0.5), cell, sampling, lod);
    return result / float(taps);
}

vec3 projected_map(sampler2D atlas, int slot, vec3 p, vec3 dx, vec3 dy, vec3 weights, int cell, vec4 sampling) {
    vec3 result=vec3(0);
    if (weights.x>0.0) result+=atlas_sample(atlas,slot,p.zy,dx.zy,dy.zy,cell,sampling)*weights.x;
    if (weights.y>0.0) result+=atlas_sample(atlas,slot,p.xz,dx.xz,dy.xz,cell,sampling)*weights.y;
    if (weights.z>0.0) result+=atlas_sample(atlas,slot,p.xy,dx.xy,dy.xy,cell,sampling)*weights.z;
    return result;
}

vec2 normal_slope(vec3 encoded, float strength) {
    // RGBA8 flat normals encode XY as 128; remove that quantization bias.
    vec2 xy = (encoded.xy * 255.0 - 128.0) / 127.0;
    float z = max(encoded.z * 2.0 - 1.0, 0.1);
    return xy / z * strength;
}

vec3 projected_gradient(sampler2D atlas, int slot, vec3 p, vec3 dx, vec3 dy, vec3 weights, vec4 sampling, float strength) {
    vec2 x = normal_slope(atlas_sample(atlas,slot,p.zy,dx.zy,dy.zy,1,sampling),strength);
    vec2 y = normal_slope(atlas_sample(atlas,slot,p.xz,dx.xz,dy.xz,1,sampling),strength);
    vec2 z = normal_slope(atlas_sample(atlas,slot,p.xy,dx.xy,dy.xy,1,sampling),strength);
    return vec3(0,x.y,x.x)*weights.x + vec3(y.x,0,y.y)*weights.y + vec3(z.x,z.y,0)*weights.z;
}

float ramp(float a, float b, float x) {
    return a == b ? step(a,x) : smoothstep(a,b,x);
}
float band(vec4 range, float value) {
    return ramp(range.x,range.y,value) * (1.0-ramp(range.z,range.w,value));
}
vec4 parameter(int layer, int row) {return texelFetch(u_parameters,ivec2(layer,row),0);}
vec4 control_group(vec2 uv, int group) {
    vec2 size = vec2(textureSize(u_controls,0));
    vec2 half_texel = 0.5 / size;
    vec2 p = vec2(uv.x,(uv.y+float(group))*0.5);
    p = clamp(p,vec2(half_texel.x,float(group)*0.5+half_texel.y),
                vec2(1.0-half_texel.x,float(group+1)*0.5-half_texel.y));
    return textureLod(u_controls,p,0.0);
}
void accumulate(sampler2D atlas, int slot, int layer, float weight,
                vec3 position, vec3 dx, vec3 dy, vec3 projections,
                inout vec3 color, inout vec3 orm, inout vec3 gradient) {
    vec4 tile = parameter(layer,3), sampling = parameter(layer,2), pbr = parameter(layer,1);
    vec3 scale = vec3(1.0/tile.x,0.5/tile.x+0.5/tile.y,1.0/tile.y);
    vec3 p=position*scale, x=dx*scale, y=dy*scale;
    color += pow(projected_map(atlas,slot,p,x,y,projections,0,sampling),vec3(2.2))*parameter(layer,0).rgb*weight;
    vec3 map=projected_map(atlas,slot,p,x,y,projections,2,sampling);
    orm += vec3(mix(1.0,map.r,pbr.x),map.g*pbr.y,map.b*pbr.z)*weight;
    if (pbr.w>0.0) gradient += projected_gradient(atlas,slot,p,x,y,projections,sampling,pbr.w)*weight;
}
void fragment() {
    vec3 n=normalize(v_terrain_normal);
    vec3 projections=pow(abs(n),vec3(4.0));
    projections/=max(projections.x+projections.y+projections.z,0.0001);
    vec3 dx=dFdx(v_terrain_position), dy=dFdy(v_terrain_position);
    float slope=degrees(acos(clamp(n.y,0.0,1.0)));
    vec4 controls_a=vec4(1), controls_b=vec4(1);
    if (u_terrain.w>0.5) {
        vec2 uv=v_terrain_position.xz/u_terrain.xy;
        controls_a=control_group(uv,0); controls_b=control_group(uv,1);
    }
    float weights[8]; float total=0.0;
    int count=int(u_terrain.z);
    for (int i=0;i<8;++i) {
        float w=0.0;
        if (i<count) {
            w=parameter(i,3).z;
            if (u_terrain.w>0.5) w *= i<4 ? controls_a[i] : controls_b[i-4];
            else w *= band(parameter(i,4),v_terrain_position.y)*band(parameter(i,5),slope);
        }
        weights[i]=w; total+=w;
    }
    if (total<0.00001) {weights[0]=1.0; total=1.0;}
    vec3 color=vec3(0), orm=vec3(0), gradient=vec3(0);
    float specular=0.0;
    for (int i=0;i<8;++i) {
        float weight=weights[i]/total;
        if (weight<=0.0) continue;
        if (i<4) accumulate(u_layers_a,i,i,weight,v_terrain_position,dx,dy,projections,color,orm,gradient);
        else accumulate(u_layers_b,i-4,i,weight,v_terrain_position,dx,dy,projections,color,orm,gradient);
        specular+=parameter(i,0).a*weight;
    }
    ALBEDO*=color;
    OCCLUSION=orm.r; ROUGHNESS=orm.g; METALNESS=orm.b; SPECULAR=specular;
    vec3 local_normal=normalize(n+gradient-n*dot(n,gradient));
    NORMAL=normalize(mat3(v_normal_x,v_normal_y,v_normal_z)*local_normal);
    NORMAL_MAP=vec3(0.5,0.5,1);
}
