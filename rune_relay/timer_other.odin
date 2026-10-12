#+build !windows
package main

relay_timer_begin :: proc() -> bool {return false}
relay_timer_end :: proc(enabled: bool) {}
