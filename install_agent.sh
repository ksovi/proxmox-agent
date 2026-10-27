#!/bin/bash
# Manual installer for the OviOS iSCSI provider (use the .deb package if you can).
# Re-runnable; see ovios-pve-patch for what gets changed.

set -e

ZFS_PM=/usr/share/perl5/PVE/Storage/ZFSPlugin.pm
PVE_JS=/usr/share/pve-manager/js/pvemanagerlib.js
HERE="$(cd "$(dirname "$0")" && pwd)"

for f in "$ZFS_PM" "$PVE_JS" "$HERE/OviOSiSCSI.pm"; do
    [ -f "$f" ] || { echo "Missing $f - is this a Proxmox VE node?" >&2; exit 1; }
done

echo "Creating backup for the files that will be changed"
# keep the first (pristine) copy only
for f in "$ZFS_PM" "$PVE_JS"; do
    [ -e "$f.original" ] || cp -v "$f" "$f.original"
done

echo "Copy the OviOS agent to the target dir"
install -v -m 0644 "$HERE/OviOSiSCSI.pm" /usr/share/perl5/PVE/Storage/LunCmd/OviOSiSCSI.pm

"$HERE/ovios-pve-patch" apply

echo "Restarting PVE services"
systemctl restart pvedaemon.service pveproxy.service pvestatd.service

echo "Open a new websession (hard refresh) to the Proxmox UI and the OviOS plugin will be available"
