#version 330

uniform sampler2D texture0;
// near, far, orthographic (0 = perspective, 1 = orthographic)
uniform vec3 u_projection;
out vec4 finalColor;

void main() {
    // Both attachments use bottom-left coordinates. Pixel addressing avoids
    // filtering across silhouettes and preserves the native sampling grid.
    float depth = texelFetch(texture0, ivec2(gl_FragCoord.xy), 0).r;
    float near = u_projection.x, far = u_projection.y;
    float distance = u_projection.z > 0.5
        ? mix(near, far, depth)
        : (2.0 * near * far) / (far + near - (2.0 * depth - 1.0) * (far - near));
    if (depth >= 1.0) distance = far;
    distance = min(distance, far);
    finalColor = vec4(distance, 0.0, 0.0, 1.0);
}
