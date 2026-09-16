# Tabbed editor mockup provenance

Generated on 2026-09-16 using the built-in image generation tool. The saved
`editor-tabs.png` is the final concept from this discussion. It was generated
as an edit of the preceding full-height editor mockup without an asset browser.
Earlier iterations are not included here.

## Final edit prompt

Use case: ui-mockup. Edit the most recent Rune editor screenshot (dark UI with NO asset browser, full-height forest platformer viewport). Primary change: make the editor document-tab based so multiple scene and prefab files can stay open simultaneously. Preserve the same overall screenshot aspect ratio, Rune branding, polished graphite/teal native UI styling, compact legible typography, hierarchy on left, full-height scene viewport center, inspector right, forest platformer art, selected Platform_02 and its inspector properties. Keep assets managed via OS file picker; no asset browser.

Add a prominent full-width document tab strip immediately below the top menu bar and above the editing toolbar, spanning the entire application workspace, so the hierarchy, viewport and inspector all belong to the active document. Four tabs, exact labels: 'main.scene.json' (active teal underline), 'cave.scene.json' (inactive, small unsaved dot), 'player.prefab.json' (inactive), 'moving_platform.prefab.json' (inactive). Scene tabs have a small scene icon, prefab tabs a small cube icon. Every tab has a close x; a small plus button follows the tabs. Tabs must be wide enough for the full filenames to be clearly readable. Visually differentiate the active document without loud colors. Below document strip keep selection/move/rotate/scale tools, Local, Snap 16, centered Play Pause Step controls, and change Save Scene toolbar button to 'Save'.

Replace the OLD central viewport tab row 'Scene / Game / main.scene.json' with a small secondary mode switch 'Scene / Game' at left and a small 'Open JSON' action at far right. The JSON file itself is represented in the main document tab strip, do not duplicate it as another document tab inside the viewport. Hierarchy header 'Hierarchy' with a muted 'Main Scene' context label, scene tree remains Main Scene / Camera2D / Player / Environment / Ground / Platform_01 / Platform_02 selected / Lights. Inspector remains Platform_02 with Transform, SpriteRenderer texture path plus OS-folder-picker button and preview, BoxCollider2D, Add Component. Maintain large useful viewport and slim bottom status bar 'scenes/main.scene.json', 'Console', '0 errors', 'Saved'. Fit everything neatly, consistent borders, precise professional UX. Screenshot only, no outer annotations, no asset dock, no embedded file manager. This is a coherent multi-document scene and prefab editor concept.
