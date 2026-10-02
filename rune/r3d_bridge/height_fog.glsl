// Integrate rho(y) = density * exp(-falloff * (y - base_height)) along
// the camera-to-surface ray. Empty sky uses a finite atmospheric distance
// independent of clipping planes, avoiding a hard band at the horizon.
// The upper layer uses a negative signed falloff to thicken upward.
uniform vec3 u_color;
uniform vec4 u_params; // base height, density, signed falloff, sky distance
uniform vec3 u_upper_color;
uniform vec4 u_upper_params;

float height_opacity(vec3 offset, vec4 params, bool sky) {
    float distance = length(offset);
    if (distance <= 0.0 || params.y <= 0.0) return 0.0;
    if (sky) {
        offset *= params.w / distance;
        distance = params.w;
    }

    float a = params.z * offset.y;
    // log((1-exp(-a))/a), with its limit at horizontal rays. Keeping
    // optical depth in log space avoids overflowing in the deep lower fog.
    float logIntegral;
    if (abs(a) < 0.01) {
        logIntegral = log(1.0 - a*0.5 + a*a/6.0);
    } else {
        logIntegral = log(1.0-exp(-abs(a))) - log(abs(a)) + max(-a, 0.0);
    }
    float logDepth = log(params.y) - params.z*(CAMERA_POSITION.y-params.x)
                   + log(distance) + logIntegral;
    return 1.0-exp(-exp(clamp(logDepth, -80.0, 3.0)));
}

void fragment() {
    COLOR = FetchColor(PIXCOORD);
    vec3 offset = mat3(MATRIX_INV_VIEW) * FetchPosition(PIXCOORD);
    bool sky = FetchDepth(PIXCOORD) >= FAR_PLANE;
    COLOR.rgb = mix(COLOR.rgb, u_color, height_opacity(offset, u_params, sky));
    COLOR.rgb = mix(COLOR.rgb, u_upper_color, height_opacity(offset, u_upper_params, sky));
}
