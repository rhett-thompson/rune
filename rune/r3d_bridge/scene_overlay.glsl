// Compose isolated foreground color after world fog/transparency, before HDR
// post processing. Never replace depth: world SSAO/fog use the world geometry.
uniform sampler2D u_overlay_color;
uniform sampler2D u_overlay_emission;
uniform vec4 u_overlay_uv; // scale.xy, bottom-left offset.zw
uniform float u_overlay_energy;
uniform int u_overlay_linear;

vec3 overlayLinear(vec3 color) {
    return u_overlay_linear != 0 ? color : pow(max(color,vec3(0.0)),vec3(2.2));
}

void fragment() {
    COLOR=FetchColor(PIXCOORD);
    vec2 uv=TEXCOORD*u_overlay_uv.xy+u_overlay_uv.zw;
    // An enlarged sampling view includes pixels outside the visible overlay.
    if(any(lessThan(uv,vec2(0.0))) || any(greaterThanEqual(uv,vec2(1.0)))) return;
    vec4 color=texture(u_overlay_color,uv);
    // Decode before compositing, preserving premultiplied coverage. Additive
    // pixels with zero alpha still contribute light without hiding the scene.
    vec3 diffuse=color.a>0.00001 ? overlayLinear(color.rgb/color.a)*color.a : overlayLinear(color.rgb);
    COLOR=COLOR*(1.0-color.a)+diffuse;
    if(u_overlay_energy>0.0) COLOR+=overlayLinear(texture(u_overlay_emission,uv).rgb)*u_overlay_energy;
}
