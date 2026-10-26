# OviOS iSCSI agent for Proxmox VE

Adds **OviOS** as an iSCSI provider to Proxmox VE's *ZFS over iSCSI* storage type, so Proxmox can
create, resize, snapshot and delete VM disks as zvols on an [OviOS Linux](https://ovios.org)
storage appliance, exported through its `tgt` iSCSI target.

Tested target: Proxmox VE 9.x. The installer uses anchor-based edits (not line-number patches),
so it is also intended to work on 7.x and 8.x.

## How it works

Proxmox's `ZFSPlugin.pm` talks to the storage box through per-provider modules in
`PVE/Storage/LunCmd/`. This repo ships one for OviOS (`OviOSiSCSI.pm`) and a small installer that:

1. copies `OviOSiSCSI.pm` to `/usr/share/perl5/PVE/Storage/LunCmd/`
2. registers the `OVIOS` provider in `ZFSPlugin.pm`
3. adds `OviOS` to the provider drop-down in `pvemanagerlib.js` (web UI)
4. restarts `pvedaemon`, `pveproxy` and `pvestatd`

The agent connects to the OviOS box as root over SSH and drives `tgtadm`, `zfs` and
`tgt-ovadmin`. The target state is read live from `tgtadm` on every operation, and the persistent
`/etc/tgt/targets.conf` is refreshed after every change.

## Install

Run on **every Proxmox node** that will use the storage, as root:

```bash
git clone <this repo> proxmox-agent
cd proxmox-agent
bash ./install_agent.sh
```

The installer is safe to re-run. The first run saves `ZFSPlugin.pm.original` and
`pvemanagerlib.js.original` next to the originals; later runs never overwrite those backups. If an
anchor in the Proxmox files can't be found, it aborts with an error rather than writing a partial
patch.

Then hard-refresh the Proxmox web UI.

> **Proxmox upgrades** replace `ZFSPlugin.pm` and `pvemanagerlib.js`. Re-run `install_agent.sh`
> after each `pve-manager` / `libpve-storage-perl` upgrade.

### Uninstall

```bash
cp /usr/share/perl5/PVE/Storage/ZFSPlugin.pm.original /usr/share/perl5/PVE/Storage/ZFSPlugin.pm
cp /usr/share/pve-manager/js/pvemanagerlib.js.original /usr/share/pve-manager/js/pvemanagerlib.js
rm /usr/share/perl5/PVE/Storage/LunCmd/OviOSiSCSI.pm
systemctl restart pvedaemon pveproxy pvestatd
```

(If Proxmox was upgraded since the install, the `.original` files are outdated; reinstall the
packages instead: `apt reinstall pve-manager libpve-storage-perl`.)

## SSH key setup

Proxmox needs passwordless root SSH to the OviOS box, using a key named after the portal IP.
Replace `192.168.43.166` with your OviOS address.

**On OviOS** — allow root SSH (before copying the key):

```
ovios-shell> options ssh.allow.root 1
ovios-shell> services restart sshd
```

**On the Proxmox node:**

```bash
mkdir -p /etc/pve/priv/zfs
ssh-keygen -f /etc/pve/priv/zfs/192.168.43.166_id_rsa -N ''
ssh-copy-id -i /etc/pve/priv/zfs/192.168.43.166_id_rsa.pub root@192.168.43.166

# test
ssh -i /etc/pve/priv/zfs/192.168.43.166_id_rsa root@192.168.43.166
```

`/etc/pve` is shared across the cluster, so the key only needs to be created once. If ssh-copy-id
isn't possible, append the `.pub` contents to `/root/.ssh/authorized_keys` on OviOS.

## Add the storage

*Datacenter → Storage → Add → ZFS over iSCSI*

| Field | Value |
|---|---|
| ID | any name |
| Portal | OviOS IP (must match the key file name) |
| Pool | ZFS pool on OviOS, e.g. `tank` |
| Target | iSCSI target IQN configured on OviOS |
| iSCSI Provider | **OviOS** |
| Block Size | e.g. `8k` |
| Thin provision | optional |

or from the CLI:

```bash
pvesm add zfs ovios --portal 192.168.43.166 --pool tank \
    --target iqn.2020-01.org.ovios:target1 --iscsiprovider OVIOS \
    --blocksize 8k --content images
```

## Behaviour notes

- Only zvols directly under `/dev/zvol/<pool>/` are managed; other LUNs on the same target are left
  alone. LUN 0 (the tgt controller) is never touched.
- Resizing a disk removes and re-adds its LUN so `tgt` picks up the new size (tgt has no online
  resize). If the re-add fails, the error says the disk is unmapped.
- Each mapped zvol gets the OviOS properties `lun:mapped`, `lun:type`, `lun:id` and `lun:tg-name`.
- `targets.conf` is written via a temp file and only replaced if the dump succeeded.

## Troubleshooting

| Symptom | Check |
|---|---|
| `OviOS` missing in the UI | hard-refresh the browser; confirm `grep OVIOS /usr/share/pve-manager/js/pvemanagerlib.js` |
| `unknown iscsi provider` | `ZFSPlugin.pm` not patched — re-run the installer |
| `unable to read target configuration` | SSH key missing/wrong name, or root SSH disabled on OviOS |
| `target ... not found` | the **Target** IQN doesn't match one shown by `tgtadm --lld iscsi --mode target --op show` on OviOS |
| Logs | `journalctl -u pvedaemon -u pvestatd -f` |

## Files

| File | Purpose |
|---|---|
| `OviOSiSCSI.pm` | the provider module |
| `install_agent.sh` | installer (idempotent, anchor-based) |
