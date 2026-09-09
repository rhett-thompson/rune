// Ground-level single scattering in an Earth-sized exponential atmosphere.
// Rayleigh and Henyey-Greenstein phase functions; midpoint optical-depth
// integration along the view ray and each sample's path toward the sun.
// Embedded in the engine; no game-side shader asset or working-directory path.
uniform vec3 u_sun_direction;
uniform vec3 u_sun_radiance;
uniform vec3 u_moon_direction;
uniform vec3 u_moon_radiance;
uniform vec3 u_night_color;
uniform vec3 u_ground_color;
uniform float u_rayleigh;
uniform float u_mie;
uniform float u_mie_anisotropy;
uniform float u_sun_radius;

const float ATM_PI = 3.14159265359;
// Kilometres keep sphere intersections well-conditioned in float precision.
const float PLANET_RADIUS = 6371.0;
const float ATMOSPHERE_RADIUS = 6471.0;
const int VIEW_SAMPLES = 16;
const int SUN_SAMPLES = 8;

vec2 sphere_interval(vec3 p, vec3 d, float radius) {
    float b = dot(p, d);
    float discriminant = b*b - dot(p,p) + radius*radius;
    if (discriminant < 0.0) return vec2(-1.0);
    float root = sqrt(discriminant);
    return vec2(-b-root, -b+root);
}

vec2 air_density(vec3 p) {
    float height = max(length(p)-PLANET_RADIUS, 0.0);
    return exp(-height / vec2(8.0, 1.2));
}

vec3 scatter_source(vec3 ray, vec3 sun, vec3 radiance, float radius) {
    if (max(radiance.r, max(radiance.g, radiance.b)) <= 0.0) return vec3(0.0);
    vec3 origin = vec3(0.0, PLANET_RADIUS + 0.1, 0.0);
    vec3 betaR = vec3(0.005802, 0.013558, 0.033100) * u_rayleigh;
    vec3 betaM = vec3(0.003996) * u_mie;
    float end = sphere_interval(origin, ray, ATMOSPHERE_RADIUS).y;
    float ground = sphere_interval(origin, ray, PLANET_RADIUS).x;
    bool hitsGround = ground > 0.0;
    if (hitsGround) end = min(end, ground);
    vec2 opticalDepth = vec2(0.0);
    vec3 sumR = vec3(0.0);
    vec3 sumM = vec3(0.0);
    // Quadratic spacing samples dense air near the observer more closely.
    for (int i = 0; i < VIEW_SAMPLES; ++i) {
        float t0 = float(i) / float(VIEW_SAMPLES);
        float t1 = float(i+1) / float(VIEW_SAMPLES);
        float stepLength = (t1*t1-t0*t0)*end;
        vec3 p = origin + ray * ((t0*t0+t1*t1)*0.5*end);
        vec2 density = air_density(p);
        vec2 viewDepth = opticalDepth + density * (0.5*stepLength);
        opticalDepth += density * stepLength;
        // Planet blocks sunlight, producing dusk and night without a fake sun.
        if (sphere_interval(p, sun, PLANET_RADIUS).x > 0.0) continue;
        float sunEnd = sphere_interval(p, sun, ATMOSPHERE_RADIUS).y;
        vec2 sunDepth = vec2(0.0);
        for (int j = 0; j < SUN_SAMPLES; ++j) {
            float s0 = float(j) / float(SUN_SAMPLES);
            float s1 = float(j+1) / float(SUN_SAMPLES);
            float ds = (s1*s1-s0*s0)*sunEnd;
            sunDepth += air_density(p + sun*((s0*s0+s1*s1)*0.5*sunEnd))*ds;
        }
        vec2 totalDepth = viewDepth + sunDepth;
        vec3 transmission = exp(-betaR*totalDepth.x - betaM*totalDepth.y*1.1);
        sumR += transmission * density.x * stepLength;
        sumM += transmission * density.y * stepLength;
    }
    float mu = clamp(dot(ray,sun), -1.0, 1.0);
    float phaseR = 3.0*(1.0+mu*mu)/(16.0*ATM_PI);
    float g = u_mie_anisotropy;
    float phaseM = (1.0-g*g)/(4.0*ATM_PI*pow(max(1.0+g*g-2.0*g*mu,0.001),1.5));
    vec3 color = radiance * (betaR*phaseR*sumR + betaM*phaseM*sumM);
    vec3 transmission = exp(-betaR*opticalDepth.x-betaM*opticalDepth.y*1.1);
    if (hitsGround) {
        float daylight = max(sun.y,0.0);
        color += u_ground_color * radiance * (daylight*0.03) * transmission;
    } else if (radius > 0.0) {
        float angle = acos(mu);
        float edge = max(fwidth(angle),0.0005);
        float disk = 1.0-smoothstep(radius-edge,radius+edge,angle);
        color += radiance * transmission * disk;
    }
    return color;
}

void fragment() {
    vec3 ray = normalize(EYEDIR);
    vec3 color = scatter_source(ray, u_sun_direction, u_sun_radiance, u_sun_radius);
    // The moon disk is drawn at scene resolution; only its haze is cached here.
    color += scatter_source(ray, u_moon_direction, u_moon_radiance, 0.0);
    // Artistic night fill is independent of a moon. Fade through twilight;
    // a disabled/zero-intensity sun also permits the full night background.
    float daylight = smoothstep(-0.18, 0.03, u_sun_direction.y);
    if (max(u_sun_radiance.r, max(u_sun_radiance.g, u_sun_radiance.b)) <= 0.0) daylight = 0.0;
    vec3 fill = u_night_color * (1.0-daylight);
    float ground = sphere_interval(vec3(0.0, PLANET_RADIUS+0.1, 0.0), ray, PLANET_RADIUS).x;
    color += fill * (ground > 0.0 ? u_ground_color : vec3(0.5+0.5*max(ray.y,0.0)));
    COLOR = max(color, vec3(0.0));
}
