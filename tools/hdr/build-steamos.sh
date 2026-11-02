#!/bin/bash -e
# Build a SteamOS-compatible HDR AppImage (glibc 2.39, like upstream CI's ubuntu-24.04 runner)
# inside a rootless podman container. Dawn and dusklight use separate build dirs, so host
# builds are untouched. Output: /media/ESSD/Dusklight/steamos/build/install/Dusklight-*.AppImage
# Usage: tools/hdr/build-steamos.sh [user@host to scp the AppImage to ~/Applications/]

ROOT=/media/ESSD/Dusklight
NAME=dusklight-u2404
JOBS="${JOBS:-22}"

cd "$(dirname "$0")/../.."
# Report the official release version: mods (e.g. ragdoll) check the host version number.
TAG="$(git describe --tags --abbrev=0 --match 'v*')"
APP_VERSION="${TAG}-hdr"

if ! podman container exists "$NAME"; then
  podman run -d --name "$NAME" --network host -v "$ROOT:$ROOT" docker.io/library/ubuntu:24.04 sleep infinity
  # Package list is upstream CI's (.github/workflows/build.yml build-linux) plus the toolchain
  # the GitHub runner image preinstalls (gcc, git, cmake, rustup).
  podman exec "$NAME" bash -ec '
    apt-get update
    DEBIAN_FRONTEND=noninteractive apt-get -y install ninja-build clang lld mold openssl \
      libcurl4-openssl-dev zlib1g-dev libglu1-mesa-dev libdbus-1-dev libvulkan-dev libxi-dev \
      libxrandr-dev libasound2-dev libpulse-dev libudev-dev libpng-dev libncurses5-dev \
      libx11-xcb-dev libfreetype-dev libxinerama-dev libxcursor-dev python3-markupsafe \
      libgtk-3-dev libssl-dev libxss-dev libfuse2 libusb-1.0-0-dev libdecor-0-dev \
      libpipewire-0.3-dev libunwind-dev gcc g++ git curl file ca-certificates pkg-config \
      python3-pip libwayland-dev libxkbcommon-dev wayland-protocols
    pip install --break-system-packages cmake
    curl -fsSL https://sh.rustup.rs | sh -s -- -y --profile minimal
    git config --global --add safe.directory "*"'
fi
podman start "$NAME" >/dev/null

podman exec -w "$ROOT" -e JOBS="$JOBS" -e APP_VERSION="$APP_VERSION" -e TAG="$TAG" "$NAME" bash -ec '
  export PATH="$HOME/.cargo/bin:$PATH"
  dawn_pkg=build-dawn/dawn-linux-x86_64-u2404.tar.gz
  if [ ! -f "$dawn_pkg" ]; then
    # Same flags as tools/hdr/build-dawn.sh, minus sccache; src already carries the HDR patch.
    cmake -S build-dawn/src -B build-dawn/build-u2404 -G Ninja \
      -C build-dawn/src/.github/workflows/dawn-ci.cmake -DCMAKE_BUILD_TYPE=Release
    cmake --build build-dawn/build-u2404 -j "$JOBS"
    cmake --install build-dawn/build-u2404 --prefix build-dawn/install-u2404
    tar -czf "$dawn_pkg" -C build-dawn/install-u2404 .
  fi

  cd dusklight
  cmake --preset x-linux-ci-gcc -B "'"$ROOT"'/steamos/build/x" \
    -DCMAKE_INSTALL_PREFIX="'"$ROOT"'/steamos/build/install" \
    -DCMAKE_C_COMPILER_LAUNCHER= -DCMAKE_CXX_COMPILER_LAUNCHER= \
    -DBOREALIS_APP_DESCRIBE_OVERRIDE="$TAG" \
    -DAURORA_DAWN_PROVIDER=package \
    -DAURORA_DAWN_PACKAGE_URL="file://'"$ROOT"'/$dawn_pkg"
  cmake --build "'"$ROOT"'/steamos/build/x" --target install -j "$JOBS"

  # ci/build-appimage.sh works relative to $GITHUB_WORKSPACE/build; give it its own workspace.
  ws="'"$ROOT"'/steamos"
  ln -sfn "'"$ROOT"'/dusklight/platforms" "$ws/platforms"
  rm -rf "$ws/build/appdir" "$ws"/build/install/Dusklight-*.AppImage
  GITHUB_WORKSPACE="$ws" APPIMAGE_EXTRACT_AND_RUN=1 bash ci/build-appimage.sh'

ls "$ROOT"/steamos/build/install/Dusklight-*.AppImage
if [ -n "$1" ]; then
  # SSH_KEY: optional identity file, e.g. ~/.ssh/legion_go2
  scp ${SSH_KEY:+-o IdentitiesOnly=yes -i "$SSH_KEY"} \
    "$ROOT"/steamos/build/install/Dusklight-*.AppImage "$1:~/Applications/"
fi
