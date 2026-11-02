#!/bin/bash -e
# Build the HDR AppImage and deploy it (plus any .dusk mods) to the test machine.

cd "$(dirname "$0")/../.."
# Report the official release version: mods (e.g. ragdoll) check the host version number.
tag="$(git describe --tags --abbrev=0 --match 'v*')"
cmake --preset x-linux-ci-gcc -DBOREALIS_APP_DESCRIBE_OVERRIDE="$tag" > /dev/null
cmake --build --preset x-linux-ci-gcc
rm -f build/install/Dusklight-*.AppImage
APP_VERSION="${tag}-hdr" ci/build-appimage.sh
scp build/install/Dusklight-*.AppImage kevinx8@192.168.1.176:~/Applications/
for mod in "$@"; do
  scp "$mod" "kevinx8@192.168.1.176:~/.local/share/TwilitRealm/Dusklight/mods/"
done
