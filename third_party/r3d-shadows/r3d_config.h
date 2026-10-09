// Layout settings of Rune's bundled R3D revision 86303391c92e32418181a8133848a15ba02f060d.
// These match the pinned CMake defaults. Private native structures depend on them.
#define R3D_SUPPORT_ASSIMP
#define R3D_MAX_SCREEN_SHADERS 4
#define R3D_MAX_SHADER_CODE_LENGTH 16384
#define R3D_MAX_SHADER_SAMPLERS 4
#define R3D_MAX_SHADER_UNIFORMS 16
#define R3D_SHADER_LIGHT_FORWARD_UBO_CAP 32
#define R3D_SHADER_PROBE_UBO_CAP 16
#define R3D_TRACELOG(level, msg, ...) TraceLog(level, "R3D: " msg, ##__VA_ARGS__)
