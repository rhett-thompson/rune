package main

import "core:fmt"
import "base:runtime"
import win "core:sys/windows"
	probe_crash :: proc "system" (exception:^win.EXCEPTION_POINTERS) -> win.LONG {
		context=runtime.default_context()
		base:=uintptr(win.GetModuleHandleW(nil))
		address:=uintptr(exception.ExceptionRecord.ExceptionAddress)
		fmt.eprintf("Native probe fault: code=0x%x, address=0x%x, module=0x%x, RVA=0x%x\n",
			exception.ExceptionRecord.ExceptionCode,address,base,address-base)
		memory:win.MEMORY_BASIC_INFORMATION
		if win.VirtualQuery(rawptr(address),&memory,size_of(memory))>0 {
			path:[1024]u16
			length:=win.GetModuleFileNameW(win.HMODULE(memory.AllocationBase),raw_data(path[:]),u32(len(path)))
			text:[4096]u8
			fmt.eprintf("Fault module: %s, module RVA=0x%x\n",win.utf16_to_utf8_buf(text[:],path[:length]),address-uintptr(memory.AllocationBase))
		}
		fmt.eprintf("Fault operation=0x%x, accessed=0x%x\n",exception.ExceptionRecord.ExceptionInformation[0],exception.ExceptionRecord.ExceptionInformation[1])
		trace:[32]win.PVOID
		count:=win.RtlCaptureStackBackTrace(0,u32(len(trace)),raw_data(trace[:]),nil)
		for frame,i in trace[:count] {fmt.eprintf("Fault trace%d: address=0x%x, EXE RVA=0x%x\n",i,uintptr(frame),uintptr(frame)-base)}
		return 0
	}
	install_probe_crash_handler :: proc() {win.SetUnhandledExceptionFilter(probe_crash)}
