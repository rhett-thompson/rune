// Bound the march to an ellipsoid and terminate at opaque scene depth.
uniform sampler2D u_noise;
uniform sampler2D u_depth;
uniform mat4 u_inverse_model;
uniform vec3 u_camera;
uniform vec3 u_forward;
uniform vec3 u_light;
uniform vec3 u_color;
uniform vec3 u_shadow;
uniform vec3 u_offset;
uniform vec3 u_settings; // extinction, noise wavelength, coverage
uniform int u_steps;

// 32 slices in an 8x4 atlas, with wrapped borders for bilinear XY sampling.
float cloudNoise(vec3 p) {
    vec3 q=fract(p)*32.0;
    float z0=floor(q.z), z1=mod(z0+1.0,32.0);
    vec2 a=vec2(mod(z0,8.0),floor(z0/8.0))*34.0;
    vec2 b=vec2(mod(z1,8.0),floor(z1/8.0))*34.0;
    vec2 uv=q.xy+1.5;
    return mix(texture(u_noise,(a+uv)/vec2(272.0,136.0)).r,
               texture(u_noise,(b+uv)/vec2(272.0,136.0)).r,fract(q.z));
}

float cloudDensity(vec3 position, bool detail) {
    vec3 local=(u_inverse_model*vec4(position,1.0)).xyz*2.0;
    float radius=dot(local,local);
    if(radius>=1.0) return 0.0;
    vec3 p=(position+u_offset)/u_settings.y;
    float noise=cloudNoise(p);
    if(detail) noise=noise*0.72+cloudNoise(p*2.07+vec3(0.13,0.37,0.61))*0.28;
    // Erode the ellipsoid with 3D noise; all six bounds fade to empty space.
    float field=noise + u_settings.z - 0.72 - radius*0.38;
    return smoothstep(0.0,0.23,field)*(1.0-smoothstep(0.65,1.0,radius));
}

void fragment() {
    // Draw back faces even inside a volume. The opaque-depth texture, rather
    // than the far side of the proxy cube, determines visible cloud length.
    gl_FragDepth=0.0;
    vec3 ray=normalize(POSITION-u_camera);
    vec3 origin=(u_inverse_model*vec4(u_camera,1.0)).xyz*2.0;
    vec3 direction=mat3(u_inverse_model)*ray*2.0;
    float aa=dot(direction,direction), bb=dot(origin,direction);
    float discriminant=bb*bb-aa*(dot(origin,origin)-1.0);
    if(discriminant<=0.0) discard;
    float begin=max(0.0,(-bb-sqrt(discriminant))/aa);
    float end=(-bb+sqrt(discriminant))/aa;
    float depth=texelFetch(u_depth,ivec2(gl_FragCoord.xy),0).r;
    end=min(end,depth/max(dot(ray,u_forward),0.0001));
    if(end<=begin) discard;
    float ds=(end-begin)/float(u_steps);
    float jitter=fract(sin(dot(gl_FragCoord.xy,vec2(12.9898,78.233)))*43758.5453);
    float transmittance=1.0;
    vec3 radiance=vec3(0.0);
    for(int i=0;i<96;i++) {
        if(i>=u_steps || transmittance<0.015) break;
        vec3 p=u_camera+ray*(begin+(float(i)+jitter)*ds);
        float density=cloudDensity(p,true);
        if(density<=0.001) continue;
        // A short light probe shades the thick interior and illuminated rim.
        float shade=cloudDensity(p+u_light*(u_settings.y*0.18),false);
        float light=exp(-shade*u_settings.x*u_settings.y*0.7);
        float opacity=1.0-exp(-density*u_settings.x*ds);
        radiance+=transmittance*opacity*mix(u_shadow,u_color,light);
        transmittance*=1.0-opacity;
    }
    ALPHA=1.0-transmittance;
    if(ALPHA<0.001) discard;
    ALBEDO=radiance/max(ALPHA,0.0001);
}
