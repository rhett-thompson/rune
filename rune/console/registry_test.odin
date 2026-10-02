package console

import "core:fmt"
import "core:testing"

registry_test_handler :: proc(dev: ^Console, arguments: string) {}

@(test)
game_commands_fit_beyond_thirty_two_and_capacity_is_checked :: proc(t: ^testing.T) {
	dev:=init(); initial:=dev.command_count
	for i in initial..<Max_Commands {
		testing.expect(t,register(&dev,fmt.tprintf("game_%d",i),"Game command",registry_test_handler))
	}
	testing.expect(t,dev.command_count==Max_Commands && dev.command_count>32)
	testing.expect(t,!register(&dev,"overflow","Full registry",registry_test_handler))
	testing.expect(t,!register(&dev,"help","Duplicate command",registry_test_handler))
}
