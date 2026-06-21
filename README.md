# Linux NFS, SMB and Mount Troubleshooter

A Linux support toolkit for diagnosing and repairing selected NFS, SMB/CIFS and network-mount problems.

## Diagnostic script

```bash
chmod +x src/network_mount_troubleshooter.sh
sudo ./src/network_mount_troubleshooter.sh
```

Test a specific server:

```bash
sudo ./src/network_mount_troubleshooter.sh --server fileserver.example.com --hours 48
```

## Repair script

Preview a repair:

```bash
chmod +x src/network_mount_repair.sh
sudo ./src/network_mount_repair.sh --mount-all --dry-run
```

Mount one `/etc/fstab` target:

```bash
sudo ./src/network_mount_repair.sh --mount /mnt/shared
```

Unmount or remount one network filesystem:

```bash
sudo ./src/network_mount_repair.sh --unmount /mnt/shared
sudo ./src/network_mount_repair.sh --remount /mnt/shared
```

Use lazy unmount only for a confirmed stale network mount:

```bash
sudo ./src/network_mount_repair.sh --unmount /mnt/shared --lazy
```

Restart installed network-filesystem client services:

```bash
sudo ./src/network_mount_repair.sh --restart-services
```

Validate and mount all configured filesystems:

```bash
sudo ./src/network_mount_repair.sh --mount-all
```

## What the repair does

- Validates `/etc/fstab` and backs it up into the report directory.
- Mounts one selected target defined in `/etc/fstab`.
- Unmounts or remounts one selected NFS or CIFS filesystem.
- Can perform a guarded lazy unmount for a stale network mount.
- Restarts installed RPC, NFS and SMB client helper services.
- Captures network-mount and failed mount-unit state before and after repair.
- Supports dry-run, confirmation prompts, logs and clear exit codes.

## Safety and limitations

Mount changes can interrupt applications using the selected share. The tool refuses unmount or remount actions against non-network filesystems. It does not edit credentials, share definitions or `/etc/fstab` automatically.

## Author

Dewald Pretorius — L2 IT Support Engineer
