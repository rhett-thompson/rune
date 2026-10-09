// Fog the opaque background before transparent clouds blend into it.
// Empty sky uses a finite atmospheric distance independent of clipping planes.
uniform vec3 u_color;
uniform vec4 u_params; // base height, density, signed falloff, sky distance
uniform vec3 u_upper_color;
uniform vec4 u_upper_params;

void fragment() {
    COLOR = FetchColor(PIXCOORD);
    vec3 offset = mat3(MATRIX_INV_VIEW) * FetchPosition(PIXCOORD);
    bool sky = FetchDepth(PIXCOORD) >= FAR_PLANE;
    COLOR.rgb = rune_height_fog(COLOR.rgb, CAMERA_POSITION, offset, sky,
                               u_color, u_params, u_upper_color, u_upper_params);
}
