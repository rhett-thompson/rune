#version 330

uniform sampler2D texture0;
uniform float u_far_distance;
out vec4 finalColor;

void main() {
    // Both attachments use bottom-left coordinates. Pixel addressing avoids
    // filtering across silhouettes and preserves the native sampling grid.
    // Native opaque depth already contains positive view-space Z for both
    // perspective and orthographic cameras. Its 65504 clear sentinel becomes
    // the camera's far distance in this caller-owned image.
    float depth = texelFetch(texture0, ivec2(gl_FragCoord.xy), 0).r;
    float distance = depth >= 65504.0 ? u_far_distance : min(depth, u_far_distance);
    finalColor = vec4(distance, 0.0, 0.0, 1.0);
}
