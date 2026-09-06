# Public alpha preparation

The alpha target is a developer who can build Rune, create an independent game,
and use JSON hot reload without help from the maintainer. The official repository
will be on GitHub; its public URL and release tag have not been chosen here.

## Engineering check

Use the toolchain recorded in `toolchain.json`. From a Rune checkout:

```powershell
./tools/release_check.ps1 -WorkingTree -Runtime
```

This tests current files, including uncommitted additions, in an isolated export
under `build/`. It exports the initialized r3d dependency, builds all examples and
validators, creates a game beside the exported engine, checks its local schema
references, and builds both default and optimized configurations with paths
containing spaces. On Windows and Linux, `-Runtime` also runs the optional runtime
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
./tools/release_check.ps1 -Runtime
```

Without `-WorkingTree`, only `HEAD` and its recorded submodule revision are
exported. This catches files that exist locally but were never committed. Both
modes require initialized local submodules and do not download dependencies.
Omit `-Runtime` for checks without graphics or audio initialization. On headless Linux,
use `xvfb-run -a pwsh -NoProfile -File tools/release_check.ps1 -Runtime` after
installing the dependencies in [Linux development](linux.md).

The GitHub [validation workflow](../.github/workflows/validate.yml) runs this
committed-snapshot check on Windows AMD64 and Ubuntu 24.04 AMD64. It uses the
checksummed release archives in `toolchain.json`. Linux runtime tests use Mesa
software rendering, Xvfb, and ALSA null output. They do not verify real GPU drivers,
audible playback, monitor layouts, or native Wayland behavior. Reports, runtime
logs, and the starter-game frame are retained as workflow artifacts for seven days.

## Publication prerequisites

- Include Rune's root [zlib license](../LICENSE) in source releases and preserve
  applicable third-party notices.
- Complete the asset source/license records in `asset_credits.json`, retaining
  required credits. Review bundled native-library notices for binary packages.
- Confirm the GitHub clone URL and require successful Windows and Linux validation
  jobs on the release commit. A workflow file alone is not evidence of a passing run.
- State the tested platform and compiler revision in the release notes.
  Windows AMD64 is locally tested; Linux verification is pending an actual Linux
  run. Complete the Linux desktop checks in [linux.md](linux.md) before claiming
  desktop coverage. macOS remains unverified.
- Have two or three developers complete [the alpha trial](alpha-trial.md), then
  fix the onboarding failures before tagging the alpha.
- Run the committed-snapshot check on the exact commit intended for the release.

An engineering pass does not mark unresolved licensing or external testing as
complete. The JSON report records the source mode, revision, compiler, runtime
coverage, and outstanding asset-credit groups separately.
