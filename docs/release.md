# Public alpha preparation

The alpha target is a developer who can build Rune, create an independent game,
and use JSON hot reload without help from the maintainer. The repository is
[rhett-thompson/rune on GitHub](https://github.com/rhett-thompson/rune).
Release checks and publication prerequisites are below.

## Engineering check

Use the toolchain recorded in `toolchain.json`. From a Rune checkout on Windows:

```powershell
.\tools\release_check.bat --working-tree --runtime
```

On Linux, run `sh tools/release_check.sh --working-tree --runtime`. Both helpers
use native OS tooling and require no additional scripting runtime.

This tests current files, including uncommitted additions, in an isolated export
under `build/`. It exports the initialized r3d dependency, builds all examples and
validators, creates a game beside the exported engine, checks its local schema
references, and builds both default and optimized configurations with paths
containing spaces. On Windows and Linux, `--runtime` also runs the optional runtime
validators, starts that game, checks its console status, pauses and steps it,
and captures a frame.
Open the saved PNG to verify the result. The empty starter scene is expected to
show only the configured background.

The export has no `.git` directory and the generated game does not depend on
paths back into the original Rune checkout. Existing `build/` outputs are excluded.
The report and exported files remain available for inspection; the check does
not delete or modify your source files, commit changes, or publish anything.

After the intended files have been committed, run the publication check:

```powershell
.\tools\release_check.bat --runtime
```

Without `--working-tree`, only `HEAD` and its recorded submodule revision are
exported. This catches files that exist locally but were never committed. Both
modes require initialized local submodules and do not download dependencies.
The r3d checkout may contain exactly Rune's recorded binding patch; unrelated
changes are rejected. The export archives the official dependency commit, then
applies the [parent-owned corrections](../third_party/r3d-compat/README.md) and
verifies every dependency file against the recorded Git blob manifest. This
preserves the fixes in an export without Git metadata.
Omit `--runtime` for checks without graphics or audio initialization. On headless Linux,
use `xvfb-run -a sh tools/release_check.sh --runtime` after
installing the dependencies in [Linux development](linux.md).

Run these checks locally on Windows AMD64 and Linux AMD64 using the toolchain
recorded in `toolchain.json`. Reports, runtime logs, and any captured starter-game
frame remain in the generated `build/release check */` directory.

## Publication prerequisites

- Include Rune's root [zlib license](../LICENSE) in source releases and preserve
  applicable third-party notices.
- Complete the asset source/license records in `asset_credits.json`, retaining
  required credits. Review bundled native-library notices for binary packages.
- Confirm the GitHub clone URL and run Windows and Linux validation locally on
  the release commit. Record the results separately for each platform.
- State the tested platform and compiler revision in the release notes.
  Windows AMD64 is locally tested. Native Linux tooling checks have run, but a full
  headless pass and desktop verification remain pending; see the recorded results
  in [linux.md](linux.md). Complete the Linux desktop checks before claiming desktop
  coverage. macOS remains unverified.
- Have two or three developers complete [the alpha trial](alpha-trial.md), then
  fix the onboarding failures before tagging the alpha.
- Run the committed-snapshot check on the exact commit intended for the release.

An engineering pass does not mark unresolved licensing or external testing as
complete. The JSON report records the source mode, revision, compiler, runtime
coverage, and outstanding asset-credit groups separately.
