#!/bin/bash -e
# Build the HDR AppImage and deploy it (plus any .dusk mods) to the test machine.

cd "$(dirname "$0")/../.."
describe="$(git describe --tags --long --dirty --match 'v*' 2>/dev/null || true)"
describe="$(printf '%s' "$describe" | sed -E 's/-[^-]+(-dirty|)$//; s/-0$//')"
rm -f build/install/Dusklight-*.AppImage
APP_VERSION="${describe}-hdr" ci/build-appimage.sh
scp build/install/Dusklight-*.AppImage kevinx8@192.168.1.176:~/Applications/
for mod in "$@"; do
  scp "$mod" "kevinx8@192.168.1.176:~/.local/share/TwilitRealm/Dusklight/mods/"
done
