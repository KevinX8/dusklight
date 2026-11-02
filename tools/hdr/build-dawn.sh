#!/usr/bin/env bash
# Build the Dawn prebuilt package used by dusklight HDR builds.
# Output: /media/ESSD/Dusklight/build-dawn/dawn-linux-x86_64.tar.gz
# Consume with:
#   -DAURORA_DAWN_PROVIDER=package -DAURORA_DAWN_PACKAGE_URL=file:///media/ESSD/Dusklight/build-dawn/dawn-linux-x86_64.tar.gz
#
# CMake flags are exactly encounter/dawn's .github/workflows/release.yml Linux job:
# the dawn-ci.cmake initial cache (clang/clang++, LLD, DAWN_USE_WAYLAND, install tree,
# monolithic static webgpu_dawn, samples/tests off) plus -DCMAKE_BUILD_TYPE=Release
# and the sccache launchers. Idempotent: re-running reuses src/build and never patches twice.
set -euo pipefail

# Never hang on git credential prompts for unreachable test-only repos.
export GIT_TERMINAL_PROMPT=0

ROOT="/media/ESSD/Dusklight/build-dawn"
SRC="$ROOT/src"
JOBS="${JOBS:-22}"
DAWN_REF="1155e0ed531126f33a1279afa029349651ca1c93"
REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
PATCH="$REPO_ROOT/extern/aurora/cmake/patches/dawn-hdr-colorspace.patch"

if [ ! -d "$SRC/.git" ]; then
    git clone https://github.com/encounter/dawn "$SRC"
fi
git -C "$SRC" checkout --quiet "$DAWN_REF"
# Exclude third_party/angle: its nested submodules include test-only repos on
# chrome-internal.googlesource.com that are not publicly accessible, and the Linux
# build never compiles ANGLE.
git -C "$SRC" submodule update --init --recursive --jobs "$JOBS" -- . ':!third_party/angle'

if git -C "$SRC" apply --reverse --check "$PATCH" 2>/dev/null; then
    echo "dawn-hdr-colorspace.patch already applied, skipping"
elif git -C "$SRC" apply --check "$PATCH" 2>/dev/null; then
    git -C "$SRC" apply "$PATCH"
    echo "dawn-hdr-colorspace.patch applied"
else
    echo "error: $PATCH applies neither forward nor reverse; reset $SRC to $DAWN_REF" >&2
    exit 1
fi

cd "$ROOT"
cmake -S src -B build -G Ninja \
    -C src/.github/workflows/dawn-ci.cmake \
    -DCMAKE_BUILD_TYPE=Release \
    -DCMAKE_C_COMPILER_LAUNCHER=sccache \
    -DCMAKE_CXX_COMPILER_LAUNCHER=sccache
cmake --build build --config Release -j "$JOBS"
cmake --install build --config Release --prefix install
tar -czf dawn-linux-x86_64.tar.gz -C install .
echo "OK: $ROOT/dawn-linux-x86_64.tar.gz"
