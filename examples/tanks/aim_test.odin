package main

import "core:testing"

@(test)
twin_stick_aim_holds_and_mouse_retakes :: proc(t: ^testing.T) {
 tank := Tank{angle = 15}
 aim_turret(&tank, {0, 1}, {}, false, true)
 testing.expect(t, tank.turret_held && tank.turret_angle == 90, "stick establishes turret heading")
 tank.angle = 180
 aim_turret(&tank, {}, {1, 0}, false, true)
 testing.expect(t, tank.turret_angle == 90, "released stick holds aim while driving")
 aim_turret(&tank, {}, {1, 0}, true, true)
 testing.expect(t, !tank.turret_held && tank.turret_angle == 0, "moving mouse retakes desktop aim")
 aim_turret(&tank, {-1, 0}, {1, 0}, true, true)
 testing.expect(t, tank.turret_held && tank.turret_angle == 180, "active stick has priority")
}

@(test)
second_tank_keeps_keyboard_hull_lock_until_stick_aim :: proc(t: ^testing.T) {
 tank := Tank{angle = 35}
 aim_turret(&tank, {}, {}, false, false)
 testing.expect(t, tank.turret_angle == 35, "keyboard turret follows hull initially")
 aim_turret(&tank, {0, -1}, {}, false, false)
 tank.angle = 80
 aim_turret(&tank, {}, {}, false, false)
 testing.expect(t, tank.turret_held && tank.turret_angle == -90, "pad 1 release keeps its heading")
 game := Tanks_Game{left = tank, right = tank}
 reset_round(&game)
 testing.expect(t, !game.left.turret_held && !game.right.turret_held, "round reset releases both aim owners")
}
