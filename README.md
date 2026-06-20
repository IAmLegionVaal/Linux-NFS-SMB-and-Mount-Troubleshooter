# Linux NFS, SMB and Mount Troubleshooter

A read-only Bash toolkit for diagnosing NFS, SMB/CIFS, stale mounts, mount timeouts, DNS, TCP reachability, permissions, and network-storage service issues.

## Checks performed

- Mounted NFS and CIFS filesystems
- Persistent mount definitions from `/etc/fstab` with password values redacted
- Mount options, source, target, filesystem type, and free space
- Basic read responsiveness for every network mount using timeouts
- NFS client statistics and mount information
- SMB client package and kernel module availability
- RPC service and portmapper context
- Systemd mount units and failed mount units
- Recent kernel and journal events related to NFS, CIFS, RPC, stale handles, timeouts, and permission failures
- Optional DNS, route, TCP 2049, TCP 445, export, and share tests for a supplied server
- Text, CSV, and JSON reports

## Usage

```bash
chmod +x src/network_mount_troubleshooter.sh
sudo ./src/network_mount_troubleshooter.sh
```

Test a specific server:

```bash
sudo ./src/network_mount_troubleshooter.sh --server fileserver.example.com --hours 48
```

## Safety

The toolkit does not mount, unmount, remount, disconnect, modify credentials, change `/etc/fstab`, restart storage services, or write test files to remote shares.

## Privacy

Credential values embedded directly in mount options are redacted from the generated report. Paths, hostnames, usernames, and share names may still be sensitive and should be reviewed before sharing.

## Requirements

- Bash 4+
- `findmnt`, `mount`, and standard GNU utilities
- Optional: `nfs-utils`/`nfs-common`, `cifs-utils`, `smbclient`, `rpcinfo`, and `showmount`

## Validation ideas

- Healthy NFS mount
- Healthy CIFS mount
- Unreachable file server
- Stale NFS handle
- Incorrect share permissions
- Failed systemd mount unit
- Host with no network mounts

## Author

Dewald Pretorius — L2 IT Support Engineer
