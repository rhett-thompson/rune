#!/bin/sh
# Run from any directory. Odin and the platform's standard shell tools are enough.
set -u

all_examples=0
runtime=0
for argument do
    case "$argument" in
        --all-examples|-AllExamples) all_examples=1 ;;
        --runtime|-Runtime) runtime=1 ;;
        --help|-h)
            echo 'Usage: sh tools/validate.sh [--all-examples] [--runtime]'
            exit 0 ;;
        *) echo "Unknown option: $argument" >&2; exit 2 ;;
    esac
done

repository_root=$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd) || exit 1
cd "$repository_root" || exit 1
if [ -d third_party/r3d-odin/r3d ]; then
    sh "$repository_root/tools/prepare_r3d.sh" || exit $?
fi
command -v odin >/dev/null 2>&1 || { echo 'Odin was not found on PATH.' >&2; exit 1; }
if [ "$runtime" -eq 1 ] && [ -z "${DISPLAY:-}" ] && [ -z "${WAYLAND_DISPLAY:-}" ]; then
    echo 'Runtime validation needs a display. On headless Linux, run under xvfb-run -a.' >&2
    exit 1
fi
if [ "$runtime" -eq 1 ]; then
    command -v timeout >/dev/null 2>&1 || { echo 'Runtime validation needs the standard Linux timeout utility.' >&2; exit 1; }
fi

mkdir -p build || exit 1
failures=0
built_validators=''
project_validator_built=0
fail() {
    echo "FAIL $*" >&2
    failures=$((failures + 1))
}
build() {
    build_name=$1
    build_package=$2
    shift 2
    if odin build "$build_package" -collection:rune=rune "-out:build/$build_name" "$@"; then
        echo "PASS build $build_name"
        case "$build_name" in
            *_validation) built_validators="$built_validators $build_name" ;;
            project_validator) project_validator_built=1 ;;
        esac
    else
        fail "build $build_name"
    fi
}
test_example() {
    if ! odin test "examples/$1" -collection:rune=rune -collection:r3d=third_party/r3d-odin "-out:build/${1}_test"; then
        fail "test $1"
    fi
}

for package in tools/*; do
    [ -d "$package" ] && [ -f "$package/main.odin" ] || continue
    name=${package##*/}
    case "$name" in
        static_mesh_material_validation|light_shafts_validation|volumetric_fog_validation|light_shadow_validation|cloud_volume_validation|billboard_validation|procedural_material_validation|terrain_validation|skybox_validation|post_processing_validation|r3d_cache_validation|model_animation_validation)
            build "$name" "$package" -collection:r3d=third_party/r3d-odin ;;
        *) build "$name" "$package" ;;
    esac
done

# Validator names are repository directory names without spaces.
for name in $built_validators; do
    "build/$name" || fail "run $name"
done
odin test rune/console -collection:rune=rune -out:build/console_test || fail 'test console'

if [ "$runtime" -eq 1 ]; then
    for name in overlay_3d_validation static_mesh_material_validation light_shafts_validation volumetric_fog_validation light_shadow_validation cloud_volume_validation billboard_validation procedural_material_validation navigation_3d_validation save_validation asset_validation terrain_validation skybox_validation post_processing_validation model_animation_validation sprite_animation_validation particle_validation component_features_validation collider_2d_validation polygon_2d_validation resolution_validation ui_validation window_validation mixer_validation console_validation; do
        case " $built_validators " in *" $name "*) ;; *) continue ;; esac
        stdout="build/$name.runtime.stdout.log"
        stderr="build/$name.runtime.stderr.log"
        timeout --kill-after=5s 90s "build/$name" --runtime >"$stdout" 2>"$stderr"
        result=$?
        case "$result" in
            0) echo "PASS runtime $name" ;;
            124|137) fail "runtime $name timed out after 90 seconds" ;;
            *) fail "runtime $name (exit $result)" ;;
        esac
        cat "$stdout" "$stderr"
    done
fi

if [ "$project_validator_built" -eq 1 ]; then
    for project in examples/*/project.json templates/blank_project/project.json; do
        [ -f "$project" ] || continue
        build/project_validator "$project" || fail "validate $project"
    done
fi
build blank_project_template templates/blank_project
build hello_world examples/hello_world
test_example planetary_3d
if [ -d third_party/r3d-odin/r3d ]; then
    build hello_3d examples/hello_3d -collection:r3d=third_party/r3d-odin
else
    fail 'r3d submodule is not initialized; run git submodule update --init --recursive'
fi

if [ "$all_examples" -eq 1 ]; then
    for name in asteroids tetris physics_platformer_2d first_person_3d third_person_3d; do
        test_example "$name"
    done
    # Discover runnable packages, including the launcher. The engine's r3d
    # collection is harmless for examples that do not import it.
    for package in examples/*; do
        [ -d "$package" ] && [ -f "$package/main.odin" ] || continue
        build "${package##*/}" "$package" -collection:r3d=third_party/r3d-odin
    done
fi

if [ "$failures" -ne 0 ]; then
    echo "Rune validation failed ($failures failures)." >&2
    exit 1
fi
echo 'Rune validation passed.'
