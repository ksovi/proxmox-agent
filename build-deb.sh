#!/bin/bash
# Builds ovios-pve-storage_<version>_all.deb into ./dist (needs dpkg-deb).
# usage: ./build-deb.sh [version]     (default: 1.0.0)

set -e

VERSION="${1:-1.0.0}"
HERE="$(cd "$(dirname "$0")" && pwd)"
STAGE="$(mktemp -d)"
trap 'rm -rf "$STAGE"' EXIT

install -d "$STAGE/DEBIAN" \
    "$STAGE/usr/share/perl5/PVE/Storage/LunCmd" \
    "$STAGE/usr/share/ovios-pve-storage"

install -m 0644 "$HERE/OviOSiSCSI.pm" "$STAGE/usr/share/perl5/PVE/Storage/LunCmd/OviOSiSCSI.pm"
install -m 0755 "$HERE/ovios-pve-patch" "$STAGE/usr/share/ovios-pve-storage/ovios-pve-patch"

sed "s/@VERSION@/$VERSION/" "$HERE/packaging/DEBIAN/control" > "$STAGE/DEBIAN/control"
install -m 0644 "$HERE/packaging/DEBIAN/triggers" "$STAGE/DEBIAN/triggers"
install -m 0755 "$HERE/packaging/DEBIAN/postinst" "$STAGE/DEBIAN/postinst"
install -m 0755 "$HERE/packaging/DEBIAN/prerm" "$STAGE/DEBIAN/prerm"

mkdir -p "$HERE/dist"
dpkg-deb --root-owner-group --build "$STAGE" "$HERE/dist/ovios-pve-storage_${VERSION}_all.deb"
