// Analytic moon disk at scene resolution, independent of cubemap face size.
uniform vec3 u_direction;
uniform vec3 u_radiance;
uniform float u_radius;
uniform float u_energy;
uniform float u_rayleigh;
uniform float u_mie;

void fragment() {
    COLOR = FetchColor(PIXCOORD);
    vec4 viewRay = MATRIX_INV_PROJECTION * vec4(TEXCOORD*2.0-1.0, 1.0, 1.0);
    vec3 ray = normalize(mat3(MATRIX_INV_VIEW) * viewRay.xyz);
    // atan stays precise for small disks; acos(dot) loses precision near 1.
    float angle = atan(length(cross(ray, u_direction)), dot(ray, u_direction));
    float edge = max(fwidth(angle)*0.5, 0.000001);
    float disk = 1.0-smoothstep(u_radius-edge, u_radius+edge, angle);
    if (disk <= 0.0 || FetchDepth(PIXCOORD) < FAR_PLANE) return;

    const float planet = 6371.0;
    const float atmosphere = 6471.0;
    vec3 origin = vec3(0.0, planet+0.1, 0.0);
    float b = dot(origin, ray);
    float c = dot(origin, origin);
    float groundDisc = b*b-c+planet*planet;
    if (groundDisc >= 0.0 && -b-sqrt(groundDisc) > 0.0) return;
    float end = -b+sqrt(max(b*b-c+atmosphere*atmosphere, 0.0));
    vec2 depth = vec2(0.0);
    // Same extinction as the sky, evaluated only over the visible disk pixels.
    for (int i = 0; i < 16; ++i) {
        float t0 = float(i)/16.0;
        float t1 = float(i+1)/16.0;
        float ds = (t1*t1-t0*t0)*end;
        vec3 p = origin+ray*((t0*t0+t1*t1)*0.5*end);
        float height = max(length(p)-planet, 0.0);
        depth += exp(-height/vec2(8.0,1.2))*ds;
    }
    vec3 betaR = vec3(0.005802,0.013558,0.033100)*u_rayleigh;
    vec3 betaM = vec3(0.003996)*u_mie;
    vec3 transmission = exp(-betaR*depth.x-betaM*depth.y*1.1);
    COLOR += u_radiance*transmission*(disk*u_energy);
}
