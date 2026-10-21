// Compile-time policy shared by the runtime and optional development tools.
package profile

// Enable with -define:RUNE_PLAYER=true. Optimized development builds retain
// their tools unless this independent player profile is explicitly selected.
Player_Build :: #config(RUNE_PLAYER, false)
