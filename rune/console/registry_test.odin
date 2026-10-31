package console

import "core:fmt"
import "core:mem"
import "core:testing"

registry_test_handler :: proc(dev: ^Console, arguments: string) {
	if dev.user_data != nil {(^int)(dev.user_data)^ += 1}
}

registry_test_completion :: proc(dev: ^Console, request: Completion_Request, candidates: ^[dynamic]string) {
	append(candidates,"overflow_argument")
}

@(test)
game_commands_fill_the_registry_and_overflow_remains_executable_and_completable :: proc(t: ^testing.T) {
	dev:=init(); defer destroy(&dev)
	initial:=dev.command_count
	testing.expect(t,dev.overflow_commands==nil,"ordinary consoles keep their inline storage")
	for i in initial..<Max_Commands {
		testing.expect(t,register(&dev,fmt.tprintf("game_%d",i),"Game command",registry_test_handler,registry_test_completion))
		if i<Inline_Commands {testing.expect(t,dev.overflow_commands==nil)}
	}
	testing.expect(t,dev.command_count==Max_Commands && dev.command_count==512 && dev.overflow_commands!=nil)
	testing.expect(t,!register(&dev,"overflow","Full registry",registry_test_handler))
	testing.expect(t,!register(&dev,"help","Duplicate command",registry_test_handler))
	calls:=0;dev.user_data=&calls
	last:=fmt.tprintf("game_%d",Max_Commands-1)
	testing.expect(t,execute(&dev,last) && calls==1,"dispatch reaches overflow storage")
	testing.expect(t,insert_text(&dev,last))
	matches:=completion_matches(&dev)
	testing.expect(t,len(matches.options)==1 && matches.options[0].value==last,"completion reaches overflow storage")
	testing.expect(t,insert_text(&dev," "))
	matches=completion_matches(&dev)
	testing.expect(t,len(matches.options)==1 && matches.options[0].value=="overflow_argument","overflow argument completion invokes its provider")
	testing.expect(t,execute(&dev,"help"))
	latest:=&dev.lines[(dev.line_start+dev.line_count-1)%Max_Log_Lines]
	testing.expect(t,string(latest.text[:latest.len])==fmt.tprintf("%s - Game command",last),"help reaches overflow storage")
}

@(test)
overflow_allocation_failure_preserves_the_registry_and_allows_retry :: proc(t: ^testing.T) {
	dev:=init();defer destroy(&dev)
	for i in dev.command_count..<Inline_Commands {
		testing.expect(t,register(&dev,fmt.tprintf("game_%d",i),"Game command",registry_test_handler))
	}
	owner:=context.allocator
	context.allocator=mem.nil_allocator()
	registered:=register(&dev,"retry","Game command",registry_test_handler)
	context.allocator=owner
	testing.expect(t,!registered && dev.command_count==Inline_Commands && dev.overflow_commands==nil)
	testing.expect(t,register(&dev,"retry","Game command",registry_test_handler))
	testing.expect(t,execute(&dev,"retry"))
}

@(test)
overflow_storage_is_released_with_its_registration_allocator :: proc(t: ^testing.T) {
	dev:=init()
	for i in dev.command_count..=Inline_Commands {
		testing.expect(t,register(&dev,fmt.tprintf("game_%d",i),"Game command",registry_test_handler))
	}
	arena:mem.Dynamic_Arena
	mem.dynamic_arena_init(&arena);defer mem.dynamic_arena_destroy(&arena)
	context.allocator=mem.dynamic_arena_allocator(&arena)
	destroy(&dev)
	testing.expect(t,dev.overflow_commands==nil && dev.command_count==0)
	destroy(&dev)
}
