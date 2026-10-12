package main

import "core:testing"

// Opt in after building rune_relay and relay_multiplayer. These exercise the
// actual child-process lifecycle without opening visible game windows.
when #config(RELAY_SESSION_SMOKE, false) {
	@(test)
	relay_launcher_process_smoke :: proc(t: ^testing.T) {
		mode := "--hidden" if #config(RELAY_SESSION_WINDOWED, false) else "--headless"
		code, error := run_relay_session(Example{path = "relay_multiplayer"}, #config(RELAY_SESSION_PREBUILT, true),
			[]string{mode, "--scripted", "--run-seconds", "3", "--console-dir=build/relay console"})
		testing.expect_value(t, error, "")
		testing.expect_value(t, code, 0)
	}

	@(test)
	relay_launcher_failed_host_cleanup :: proc(t: ^testing.T) {
		code, error := run_relay_session(Example{path = "relay_multiplayer"}, true,
			[]string{"--unknown-relay-game-option"})
		testing.expect(t, code != 0)
		testing.expect(t, error != "")
	}
}
