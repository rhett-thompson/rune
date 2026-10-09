// Shared by the opaque-background pass and cloud samples. The upper layer
// uses a negative signed falloff to thicken upward.
float rune_height_opacity(vec3 camera, vec3 offset, vec4 params, bool sky) {
    float distance = length(offset);
    if (distance <= 0.0 || params.y <= 0.0) return 0.0;
    if (sky) {
        offset *= params.w / distance;
        distance = params.w;
    }
    float a = params.z * offset.y;
    // Keep optical depth in log space to avoid overflow in dense layers.
    float logIntegral;
    if (abs(a) < 0.01) {
        logIntegral = log(1.0 - a*0.5 + a*a/6.0);
    } else {
        logIntegral = log(1.0-exp(-abs(a))) - log(abs(a)) + max(-a, 0.0);
    }
    float logDepth = log(params.y) - params.z*(camera.y-params.x)
                   + log(distance) + logIntegral;
    return 1.0-exp(-exp(clamp(logDepth, -80.0, 3.0)));
}

vec3 rune_height_fog(vec3 radiance, vec3 camera, vec3 offset, bool sky,
                     vec3 lowerColor, vec4 lowerParams,
                     vec3 upperColor, vec4 upperParams) {
    radiance = mix(radiance, lowerColor, rune_height_opacity(camera, offset, lowerParams, sky));
    return mix(radiance, upperColor, rune_height_opacity(camera, offset, upperParams, sky));
}
