// Radially blur an occlusion mask toward the source. Near-pixel samples carry
// more weight, so silhouettes become long shadow wedges rather than a halo.
uniform vec3 u_source; // bottom-left UV and positive view-space depth
uniform vec3 u_color;
uniform vec4 u_settings; // intensity, screen radius, world emitter radius, aspect
uniform float u_disk_radius;
uniform float u_edge_fade;
uniform int u_samples;
uniform vec2 u_resolution;

float clearPath(vec2 uv) {
    if(any(lessThan(uv,vec2(0.0))) || any(greaterThanEqual(uv,vec2(1.0)))) return 0.0;
    float depth=FetchDepth(ivec2(uv*u_resolution));
    if(depth>=FAR_PLANE-0.01) return 1.0;
    // All architecture masks the scattering sky, including geometry farther
    // away than the finite emitter. Only the emitter's own footprint is clear.
    float radius=length((uv-u_source.xy)*vec2(u_settings.w,1.0));
    return radius<=u_disk_radius && abs(depth-u_source.z)<=u_settings.z+0.5 ? 1.0 : 0.0;
}

void fragment() {
    COLOR=FetchColor(PIXCOORD);
    vec2 aspect=vec2(u_settings.w,1.0);
    float distance=length((TEXCOORD-u_source.xy)*aspect);
    float envelope=1.0-smoothstep(u_settings.y*0.6,u_settings.y,distance);
    if(envelope<=0.0) return;
    // Scatter in front of surfaces too: testing only the destination pixel
    // clips the rays to sky holes and removes the streaks across foreground.
    // Stop short of the core, which otherwise fills every shadow with light.
    // A fixed per-pixel offset breaks up the repeated silhouette bands from
    // regularly spaced taps. It stays still when the simulation is paused.
    float jitter=fract(52.9829189*fract(dot(vec2(PIXCOORD),vec2(0.06711056,0.00583715))));
    float sum=0.0, normalization=0.0;
    for(int i=0;i<64;i++) {
        if(i>=u_samples) break;
        float t=(float(i)+jitter)/float(u_samples)*0.85;
        vec2 uv=mix(TEXCOORD,u_source.xy,t);
        float r=length((uv-u_source.xy)*aspect)/u_settings.y;
        float weight=exp(-t*4.0);
        sum+=clearPath(uv)*exp(-r*r*2.0)*weight;
        normalization+=weight;
    }
    COLOR+=u_color*(sum/normalization)*envelope*u_settings.x*u_edge_fade;
}
