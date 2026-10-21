package core

import "rune:profile"

// Player_Build is fixed at compilation by -define:RUNE_PLAYER=true. Project
// JSON and mutable runtime settings cannot re-enable development tools.
Player_Build :: profile.Player_Build

@(private)
apply_project_profile :: proc(project: ^Project) {
	when Player_Build {
		project.window.show_fps = false
		project.hot_reload = {}
		project.gizmos = {}
	}
}
