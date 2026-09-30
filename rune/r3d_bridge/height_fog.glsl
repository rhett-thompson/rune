// Integrate rho(y) = density * exp(-falloff * (y - base_height)) along
// the camera-to-surface ray. Empty sky uses a finite atmospheric distance
// independent of clipping planes, avoiding a hard band at the horizon.
uniform vec3 u_color;
uniform float u_base_height;
uniform float u_density;
uniform float u_falloff;
uniform float u_sky_distance;

void fragment() {
    COLOR = FetchColor(PIXCOORD);
    vec3 offset = mat3(MATRIX_INV_VIEW) * FetchPosition(PIXCOORD);
    float distance = length(offset);
    if (distance <= 0.0 || u_density <= 0.0) return;
    if (FetchDepth(PIXCOORD) >= FAR_PLANE) {
        offset *= u_sky_distance / distance;
        distance = u_sky_distance;
    }

    float a = u_falloff * offset.y;
    // log((1-exp(-a))/a), with its limit at horizontal rays. Keeping
    // optical depth in log space avoids overflowing in the deep lower fog.
    float logIntegral;
    if (abs(a) < 0.01) {
        logIntegral = log(1.0 - a*0.5 + a*a/6.0);
    } else {
        logIntegral = log(1.0-exp(-abs(a))) - log(abs(a)) + max(-a, 0.0);
    }
    float logDepth = log(u_density) - u_falloff*(CAMERA_POSITION.y-u_base_height)
                   + log(distance) + logIntegral;
    float opacity = 1.0-exp(-exp(clamp(logDepth, -80.0, 3.0)));
    COLOR.rgb = mix(COLOR.rgb, u_color, opacity);
}
