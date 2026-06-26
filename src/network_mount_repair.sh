#!/usr/bin/env bash
set -u

ACTION=""
TARGET=""
LAZY=false
RESTART_SERVICES=false
DRY_RUN=false
ASSUME_YES=false
OUTPUT_DIR=""
FAILURES=0
ACTIONS=0

usage() {
  cat <<'EOF'
Usage: network_mount_repair.sh [options]

  --mount TARGET          Mount one target defined in /etc/fstab.
  --unmount TARGET        Unmount one selected network mount.
  --remount TARGET        Remount one selected mounted network filesystem.
  --mount-all             Validate /etc/fstab and mount all configured filesystems.
  --restart-services      Restart installed NFS/CIFS client helper services.
  --lazy                  Use lazy unmount with --unmount.
  --dry-run               Show commands without changing the system.
  --yes                   Skip confirmation prompts.
  --output DIR            Save logs, backups and verification output in DIR.
EOF
}

while [ "$#" -gt 0 ]; do
  case "$1" in
    --mount) ACTION="mount"; TARGET="${2:-}"; shift 2 ;;
    --unmount) ACTION="unmount"; TARGET="${2:-}"; shift 2 ;;
    --remount) ACTION="remount"; TARGET="${2:-}"; shift 2 ;;
    --mount-all) ACTION="mount-all"; shift ;;
    --restart-services) RESTART_SERVICES=true; shift ;;
    --lazy) LAZY=true; shift ;;
    --dry-run) DRY_RUN=true; shift ;;
    --yes) ASSUME_YES=true; shift ;;
    --output) OUTPUT_DIR="${2:-}"; shift 2 ;;
    -h|--help) usage; exit 0 ;;
    *) echo "Unknown argument: $1" >&2; usage; exit 2 ;;
  esac
done

if [ -z "$ACTION" ] && ! $RESTART_SERVICES; then echo "Choose at least one repair action." >&2; exit 2; fi
if [ "$ACTION" = "mount" ] || [ "$ACTION" = "unmount" ] || [ "$ACTION" = "remount" ]; then [ -n "$TARGET" ] || { echo "A target is required." >&2; exit 2; }; fi
if $LAZY && [ "$ACTION" != "unmount" ]; then echo "--lazy requires --unmount TARGET." >&2; exit 2; fi

STAMP=$(date +%Y%m%d_%H%M%S)
OUTPUT_DIR="${OUTPUT_DIR:-./network-mount-repair-$STAMP}"
BACKUP_DIR="$OUTPUT_DIR/backup"
mkdir -p "$OUTPUT_DIR" "$BACKUP_DIR"
LOG="$OUTPUT_DIR/repair.log"
BEFORE="$OUTPUT_DIR/before.txt"
AFTER="$OUTPUT_DIR/after.txt"
: > "$LOG"

log() { printf '%s %s\n' "$(date '+%Y-%m-%d %H:%M:%S')" "$*" | tee -a "$LOG"; }
confirm() { $ASSUME_YES && return 0; read -r -p "$1 [y/N]: " answer; case "$answer" in y|Y|yes|YES) return 0 ;; *) return 1 ;; esac; }
run_action() {
  local description="$1"; shift
  ACTIONS=$((ACTIONS + 1)); log "$description"
  if $DRY_RUN; then
    {
      printf 'DRY-RUN:'
      printf ' %q' "$@"
      printf '\n'
    } >> "$LOG"
    return 0
  fi
  if "$@" >> "$LOG" 2>&1; then log "SUCCESS: $description"; return 0; fi
  FAILURES=$((FAILURES + 1)); log "WARNING: $description failed"; return 1
}
run_root() { local description="$1"; shift; if [ "$(id -u)" -eq 0 ]; then run_action "$description" "$@"; else run_action "$description" sudo "$@"; fi; }
collect_state() {
  local destination="$1"
  {
    echo "Collected: $(date -Is)"
    findmnt -t nfs,nfs4,cifs 2>&1 || true
    echo
    findmnt --verify --verbose 2>&1 || true
    echo
    systemctl --failed --type=mount --no-pager 2>&1 || true
    echo
    systemctl list-units --type=mount --all --no-pager 2>&1 || true
    echo
    journalctl -n 150 --no-pager 2>/dev/null | grep -Ei 'nfs|cifs|smb|mount|rpc|stale|timeout|permission denied' || true
    if [ -n "$TARGET" ]; then echo; findmnt "$TARGET" 2>&1 || true; fi
  } > "$destination"
}
restart_client_services() {
  local found=false
  for unit in rpc-statd.service rpcbind.service nfs-client.target nfs-client.service remote-fs.target winbind.service; do
    if systemctl list-unit-files "$unit" >/dev/null 2>&1; then
      found=true
      case "$unit" in
        *.target) run_root "Starting $unit" systemctl start "$unit" || true ;;
        *) run_root "Restarting $unit" systemctl restart "$unit" || true ;;
      esac
    fi
  done
  $found || { FAILURES=$((FAILURES + 1)); log "WARNING: no supported network-filesystem client service was found."; }
}

collect_state "$BEFORE"
if [ -f /etc/fstab ]; then
  cp -a /etc/fstab "$BACKUP_DIR/fstab" 2>/dev/null || true
fi
confirm "Apply the selected network-mount repairs? Applications using the mount may be interrupted." || { log "Repair cancelled."; exit 10; }

$RESTART_SERVICES && restart_client_services

case "$ACTION" in
  mount)
    grep -Ev '^[[:space:]]*(#|$)' /etc/fstab 2>/dev/null | awk '{print $2}' | grep -Fxq "$TARGET" || { log "Target is not defined in /etc/fstab: $TARGET"; exit 20; }
    run_root "Mounting $TARGET from /etc/fstab" mount "$TARGET" || true
    ;;
  unmount)
    findmnt -rn "$TARGET" >/dev/null 2>&1 || { log "Target is not mounted: $TARGET"; exit 20; }
    FSTYPE=$(findmnt -rn -o FSTYPE "$TARGET" 2>/dev/null || true)
    case "$FSTYPE" in nfs|nfs4|cifs) : ;; *) log "Refusing to unmount non-network filesystem type: $FSTYPE"; exit 20 ;; esac
    if $LAZY; then run_root "Lazily unmounting $TARGET" umount -l "$TARGET" || true; else run_root "Unmounting $TARGET" umount "$TARGET" || true; fi
    ;;
  remount)
    findmnt -rn "$TARGET" >/dev/null 2>&1 || { log "Target is not mounted: $TARGET"; exit 20; }
    FSTYPE=$(findmnt -rn -o FSTYPE "$TARGET" 2>/dev/null || true)
    case "$FSTYPE" in nfs|nfs4|cifs) : ;; *) log "Refusing to remount non-network filesystem type: $FSTYPE"; exit 20 ;; esac
    run_root "Remounting $TARGET" mount -o remount "$TARGET" || true
    ;;
  mount-all)
    run_root "Validating /etc/fstab" findmnt --verify --verbose || true
    run_root "Mounting configured filesystems" mount -a || true
    ;;
  '') : ;;
esac

$DRY_RUN || sleep 3
collect_state "$AFTER"
if [ "$ACTION" = "mount" ] || [ "$ACTION" = "remount" ]; then findmnt -rn "$TARGET" >/dev/null 2>&1 || { FAILURES=$((FAILURES + 1)); log "WARNING: $TARGET is not mounted after repair."; }; fi
if [ "$ACTION" = "unmount" ]; then findmnt -rn "$TARGET" >/dev/null 2>&1 && { FAILURES=$((FAILURES + 1)); log "WARNING: $TARGET remains mounted after repair."; }; fi
if [ "$FAILURES" -gt 0 ]; then exit 20; fi
log "Repair completed successfully. Actions performed: $ACTIONS"
exit 0
