#!/bin/bash
# Installs the OviOS iSCSI provider into Proxmox VE (7.x, 8.x, 9.x).
# Edits are anchor based (not line-number patches) so they survive upstream
# changes to ZFSPlugin.pm / pvemanagerlib.js, and the script is re-runnable.

set -e

ZFS_PM=/usr/share/perl5/PVE/Storage/ZFSPlugin.pm
LUNCMD_DIR=/usr/share/perl5/PVE/Storage/LunCmd
PVE_JS=/usr/share/pve-manager/js/pvemanagerlib.js
HERE="$(cd "$(dirname "$0")" && pwd)"

for f in "$ZFS_PM" "$PVE_JS" "$HERE/OviOSiSCSI.pm"; do
    [ -f "$f" ] || { echo "Missing $f - is this a Proxmox VE node?" >&2; exit 1; }
done

backup() {
    # keep the first (pristine) copy only
    [ -e "$1.original" ] || cp -v "$1" "$1.original"
}

echo "Creating backup for the files that will be changed"
backup "$ZFS_PM"
backup "$PVE_JS"

echo "Copy the OviOS agent to the target dir"
install -v -m 0644 "$HERE/OviOSiSCSI.pm" "$LUNCMD_DIR/OviOSiSCSI.pm"

echo "Patching ZFSPlugin.pm"
if grep -q 'LunCmd::OviOSiSCSI' "$ZFS_PM"; then
    echo "  already patched, skipping"
else
    perl -0pi -e '
        my $n = 0;
        $n += s/^(use PVE::Storage::LunCmd::LIO;\n)/$1use PVE::Storage::LunCmd::OviOSiSCSI;\n/m;
        $n += s/(Available \[[^\]]*?)\]/$1, OVIOS]/;
        $n += s/^([ \t]*)(\} elsif \(\$scfg->\{iscsiprovider\} eq .LIO.\) \{\n[ \t]*return PVE::Storage::LunCmd::LIO::get_base;\n)/$1$2$1\} elsif (\$scfg->{iscsiprovider} eq \x27OVIOS\x27) {\n$1    return PVE::Storage::LunCmd::OviOSiSCSI::get_base;\n/m;
        $n += s/^([ \t]*)(\} elsif \(\$scfg->\{iscsiprovider\} eq .LIO.\) \{\n[ \t]*\$msg = PVE::Storage::LunCmd::LIO::run_lun_command\([^\n]*\n)/$1$2$1\} elsif (\$scfg->{iscsiprovider} eq \x27OVIOS\x27) {\n$1    \$msg = PVE::Storage::LunCmd::OviOSiSCSI::run_lun_command(\$scfg, \$timeout, \$method, \@params);\n/m;
        die "ZFSPlugin.pm: expected 4 anchors, matched $n - file layout changed\n" if $n != 4;
    ' "$ZFS_PM"
    perl -c -I/usr/share/perl5 "$ZFS_PM" 2>&1 | tail -1
fi

echo "Patching pvemanagerlib.js"
if grep -q "'OVIOS'" "$PVE_JS"; then
    echo "  already patched, skipping"
else
    perl -0pi -e "s/^([ \t]*)(\['LIO', 'LIO'\],\n)/\$1\$2\$1\['OVIOS', 'OviOS'\],\n/m or die \"pvemanagerlib.js: LIO anchor not found\n\"" "$PVE_JS"
fi

echo "Restarting PVE services"
systemctl restart pvedaemon.service pveproxy.service pvestatd.service

echo "Open a new websession (hard refresh) to the Proxmox UI and the OviOS plugin will be available"
