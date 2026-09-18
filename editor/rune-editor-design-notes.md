# Rune Editor — Living Design Notes

## Core Philosophy

- **Rune Editor is optional.** It is a graphical client of Rune rather than the authority over a project.
- Project data should remain understandable and editable outside the editor.
- Rune itself owns the engine/runtime data model; the editor presents and manipulates that model.
- Avoid duplicating operating-system functionality when the OS already provides a good solution.

## Editor Architecture

The editor should use a cross-platform HTML/CSS-based shell for editor chrome while Rune owns native rendering surfaces.

The HTML shell can provide:

- Hierarchy
- Inspector
- Document tabs
- Toolbars
- Menus
- Settings and other conventional editor UI

Rune provides the actual 3D/2D scene and game rendering surfaces.

The scene view is effectively Rune rendering the world with an **editor-only overlay/runtime layer** for:

- Selection
- Picking
- Grid rendering
- Translate/rotate/scale gizmos
- Selection outlines
- Debug visualization
- Editor camera controls

These features should not need to become part of a shipped game's runtime behavior.

Communication between the shell and Rune should use a small, well-defined bridge rather than duplicating engine state in the HTML application.

## Scenes and Prefabs

Scenes and prefabs remain separate concepts.

A **scene** represents a world/runtime boundary and has responsibilities related to things such as startup, lifecycle, loading, and potentially streaming.

A **prefab** represents reusable entity composition.

Although they may share much of their serialized structure and editor UI, they retain different semantics.

### Startup Scene vs. Editor Workspace

The Rune project defines a startup/main scene used when running the game.

Opening a project in Rune Editor should not necessarily open that startup scene. The editor should maintain its own workspace state and restore things such as:

- Previously open scenes
- Previously open prefabs
- Active document/tab
- Potentially panel layout and editor camera state

This keeps runtime configuration separate from editor workflow.

## Prefab Editing

Selecting a prefab instance in a scene edits the **instance**, including its instance-specific overrides.

An explicit **Edit Prefab Source** action opens the source prefab as its own document/tab.

The editor should never silently switch from editing an instance to modifying the source prefab.

### Overrides

The source prefab establishes defaults. Instance overrides always take precedence over those defaults.

The inspector should make overridden properties visually identifiable.

Expected operations include:

- Revert Override
- Revert All Overrides
- Apply Override to Prefab
- Apply All Overrides to Prefab

When an override is applied to the source prefab, other instances receive the new source value unless they have their own override for that property.

Example:

- Source prefab health: `100`
- Instance A health: `100`
- Instance B override: `150`
- Instance A is changed to `200` and applied to the source.

Result:

- Source prefab health: `200`
- Instance A: `200`, no longer overridden
- Instance B: `150`, because its override still wins

### Apply to Source and All Instances

A stronger operation may be provided to update the source **and remove matching overrides from all instances**, forcing those instances back onto the new prefab default.

Because this is destructive, it should be an explicit bulk operation with confirmation. The editor should ideally report how many instance overrides will be cleared.

### Nested Prefabs

Nested prefab instances should be represented clearly in the hierarchy.

Overrides remain associated with the boundary at which they were authored. Opening a nested prefab's source should open that prefab as a separate document rather than silently changing its source through an enclosing instance.

## OS File Manager as Asset Browser

Rune Editor should not require a traditional Unity/Godot-style asset browser.

The operating system's file manager is already the project's general-purpose file browser.

Rune should therefore lean on normal files, folders, and OS behavior.

The editor can still provide context-specific file pickers or search where useful without maintaining a second virtual representation of the project's filesystem.

### Semantic File Extensions

Rune documents can remain human-readable JSON internally while using Rune-specific file extensions, for example:

- `.rscene`
- `.rprefab`

These extensions can be associated with Rune Editor at the operating-system level.

Double-clicking a Rune document should open it in Rune Editor and, where possible, locate/open its containing Rune project.

The exact extension names remain subject to final naming decisions.

## Components

### Add Component

The **Add Component** UI should be an autocomplete/searchable list containing both:

- Rune built-in components
- Developer-defined custom components

The HTML/editor layer should **not** maintain a hard-coded component list.

Instead, the list comes from Rune's live component registry for the loaded project.

If a component is registered with Rune, it can appear in Add Component. If it is not registered, it does not appear.

The editor may visually group results, for example:

- Rune
- Game

but they should participate in the same search/autocomplete experience.

### Component Metadata

Rune's component registration/reflection metadata should provide enough information for the editor to inspect custom components without source-code scanning.

Useful metadata includes:

- Component name
- Field names
- Field types
- Optional editor hints
- Source file
- Source line/location

This makes the runtime registry the source of truth for editor component discovery.

## Adding and Removing Components at Runtime

Rune supports component mutation on live entities.

The editor should use essentially the same interaction in edit and play modes while maintaining a clear persistence boundary.

### Edit Mode

Adding/removing a component:

1. Mutates the editor/runtime representation.
2. Persists the change to the appropriate scene or prefab document.

### Play Mode

Adding/removing a component:

1. Mutates the live runtime entity.
2. Does **not** persist back to the scene/prefab by default.

This distinction should be clear to the user so experimentation during play does not unexpectedly modify project files.

## External Code Editor Integration

Rune Editor should not attempt to become an Odin IDE.

When a component or system has associated source metadata, the editor should provide an **Edit Source** action.

For example, clicking Edit Source on a custom component could open VS Code directly to:

- The project's existing VS Code workspace/window
- The relevant `.odin` file
- Ideally the exact source line

The preferred external editor should be configurable.

VS Code can be the default when detected, but the architecture should not depend specifically on VS Code.

Source locations can be captured or associated during component/system registration so the editor does not need to search source files heuristically.

## Enhanced JSON Editing

JSON remains an important part of Rune's user-facing development model rather than something the editor hides.

Rune Editor can provide a custom/enhanced JSON text editor that progressively enhances known values with appropriate controls.

Examples:

- Boolean → checkbox
- Enum → dropdown
- Numeric value with range metadata → slider
- Color → color picker
- Asset/file reference → file picker
- Entity/component reference → appropriate selector

The underlying serialized representation remains readable text.

Where practical, users should still be able to type values directly rather than being forced to use graphical controls.

This creates a hybrid between a conventional property inspector and editing Rune's actual project data: **JSON as UI rather than JSON hidden behind UI.**

## Guiding Principle

The editor should avoid becoming a second engine.

Rune knows:

- What entities exist
- What components exist
- What fields those components contain
- How scenes and prefabs work
- How runtime mutation works
- How Rune renders a world

The editor provides convenient visual interaction with those capabilities.

That separation is especially important because Rune projects should remain viable without Rune Editor.
