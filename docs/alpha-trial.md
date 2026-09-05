# First-user alpha trial

This is a brief to give two or three developers after the license/asset questions
are resolved and the GitHub repository is available. No invitations have been sent.
Allow about 20–30 minutes and ask testers to use only the repository documentation.

## Tasks

1. Clone the GitHub repository with submodules and follow README setup. Record
   the OS, `odin version`, and PowerShell version.
2. Run `tools/validate.ps1 -AllExamples`. Save any error output.
3. Use `tools/new_project.ps1` to create a game outside the engine folder. Build
   and run it using its own `build.ps1`. Confirm the empty scene opens.
4. Run the Tilemap 2D example from the launcher. Move the knight, then save a
   small scene change and confirm hot reload. Restore the scene afterward.
5. Start the example with a console inbox. Use `status`, `pause`, `inspect`,
   `step`, and `capture`; locate and open the captured PNG.
6. Follow the README's custom component example to make a small gameplay change.
   Record any API or ownership rule that required guessing.

## Report

- Exact checkout commit, OS, compiler, and shell versions.
- Time to the first running example and to the independent project.
- First failing command, complete output, and expected result.
- Documentation passages that were missing, ambiguous, or incorrect.
- A screenshot or capture for rendering problems.
- Whether the task needed help from the maintainer.

Success means the tester finishes without unpublished setup steps or maintainer
intervention. Record failures as onboarding bugs with reproducible commands.
