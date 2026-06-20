#!/usr/bin/env bash
set -u

SERVER=""
HOURS=24
TIMEOUT_SECONDS=5
OUTPUT_DIR=""

usage() {
  echo "Usage: network_mount_troubleshooter.sh [--server HOST] [--hours N] [--timeout N] [--output DIR]"
}

while [[ $# -gt 0 ]]; do
  case "$1" in
    --server) SERVER="${2:-}"; shift 2 ;;
    --hours) HOURS="${2:-24}"; shift 2 ;;
    --timeout) TIMEOUT_SECONDS="${2:-5}"; shift 2 ;;
    --output) OUTPUT_DIR="${2:-}"; shift 2 ;;
    -h|--help) usage; exit 0 ;;
    *) echo "Unknown argument: $1" >&2; usage; exit 2 ;;
  esac
done

[[ "$HOURS" =~ ^[0-9]+$ ]] || { echo "--hours must be numeric" >&2; exit 2; }
[[ "$TIMEOUT_SECONDS" =~ ^[0-9]+$ ]] || { echo "--timeout must be numeric" >&2; exit 2; }

STAMP="$(date +%Y%m%d_%H%M%S)"
OUTPUT_DIR="${OUTPUT_DIR:-./network-mount-troubleshooting-$STAMP}"
mkdir -p "$OUTPUT_DIR"
REPORT="$OUTPUT_DIR/network-mount-report.txt"
CSV="$OUTPUT_DIR/network-mounts.csv"
JSON="$OUTPUT_DIR/summary.json"
ERRORS="$OUTPUT_DIR/command-errors.log"
: > "$REPORT"
: > "$ERRORS"

echo 'source,target,fstype,options,size_bytes,available_bytes,used_percent,responsive,status' > "$CSV"

section() {
  local title="$1"
  shift
  {
    printf '\n===== %s =====\n' "$title"
    "$@"
  } >> "$REPORT" 2>> "$ERRORS" || true
}

have() { command -v "$1" >/dev/null 2>&1; }

csv_escape() {
  local value="$1"
  value="${value//"/""}"
  printf '"%s"' "$value"
}

redact_mount_secrets() {
  sed -E \
    -e 's/(password|passwd|pass)=[^,[:space:]]+/\1=REDACTED/Ig' \
    -e 's/(credentials|cred)=[^,[:space:]]+/\1=REDACTED/Ig'
}

section "Collection metadata" bash -c 'date -Is; hostname -f 2>/dev/null || hostname; cat /etc/os-release 2>/dev/null || true; id'
section "All mounted filesystems" findmnt -A
section "Network mounts" bash -c 'findmnt -t nfs,nfs4,cifs,smb3 -o SOURCE,TARGET,FSTYPE,OPTIONS,SIZE,AVAIL,USE% 2>/dev/null || true'
section "Filesystem usage" df -hT
section "Systemd mount units" bash -c 'systemctl list-units --type=mount --all --no-pager 2>/dev/null || true'
section "Failed mount units" bash -c 'systemctl --failed --type=mount --no-pager 2>/dev/null || true'
section "NFS client statistics" bash -c 'nfsstat -c 2>/dev/null || true'
section "RPC services" bash -c 'rpcinfo -p 2>/dev/null || true'
section "Loaded network filesystem modules" bash -c 'lsmod 2>/dev/null | grep -Ei "^(nfs|nfsv4|cifs|sunrpc)" || true'

{
  printf '\n===== Redacted persistent mount configuration =====\n'
  if [[ -r /etc/fstab ]]; then
    redact_mount_secrets < /etc/fstab
  else
    echo '/etc/fstab is not readable.'
  fi
} >> "$REPORT" 2>> "$ERRORS"

if have journalctl; then
  section "Recent network storage events" bash -c "journalctl --since '$HOURS hours ago' --no-pager 2>/dev/null | grep -Ei 'nfs|cifs|smb|rpc|stale file handle|server not responding|timed out|permission denied|mount.*fail|transport endpoint|host is down|no route to host' | tail -n 1000 || true"
fi

if have dmesg; then
  section "Kernel network storage indicators" bash -c 'dmesg 2>/dev/null | grep -Ei "nfs|cifs|smb|rpc|stale file handle|server not responding|timed out|permission denied|transport endpoint" | tail -n 1000 || true'
fi

TOTAL_MOUNTS=0
RESPONSIVE_MOUNTS=0
UNRESPONSIVE_MOUNTS=0
LOW_SPACE_MOUNTS=0

while IFS=$'\t' read -r source target fstype options; do
  [[ -z "$target" ]] && continue
  TOTAL_MOUNTS=$((TOTAL_MOUNTS + 1))

  responsive=false
  status="OK"
  if have timeout; then
    if timeout "$TIMEOUT_SECONDS" stat -c '%n' "$target" >/dev/null 2>> "$ERRORS"; then
      responsive=true
      RESPONSIVE_MOUNTS=$((RESPONSIVE_MOUNTS + 1))
    else
      UNRESPONSIVE_MOUNTS=$((UNRESPONSIVE_MOUNTS + 1))
      status="UNRESPONSIVE"
    fi
  else
    if stat -c '%n' "$target" >/dev/null 2>> "$ERRORS"; then
      responsive=true
      RESPONSIVE_MOUNTS=$((RESPONSIVE_MOUNTS + 1))
    else
      UNRESPONSIVE_MOUNTS=$((UNRESPONSIVE_MOUNTS + 1))
      status="UNRESPONSIVE"
    fi
  fi

  size_bytes="$(df -P -B1 "$target" 2>/dev/null | awk 'NR==2 {print $2}')"
  available_bytes="$(df -P -B1 "$target" 2>/dev/null | awk 'NR==2 {print $4}')"
  used_percent="$(df -P "$target" 2>/dev/null | awk 'NR==2 {gsub("%", "", $5); print $5}')"
  used_percent="${used_percent:-0}"

  if [[ "$used_percent" -ge 90 ]]; then
    LOW_SPACE_MOUNTS=$((LOW_SPACE_MOUNTS + 1))
    [[ "$status" == "OK" ]] && status="LOW_SPACE"
  fi

  safe_options="$(printf '%s' "$options" | redact_mount_secrets)"
  printf '%s,%s,%s,%s,%s,%s,%s,%s,%s\n' \
    "$(csv_escape "$source")" \
    "$(csv_escape "$target")" \
    "$(csv_escape "$fstype")" \
    "$(csv_escape "$safe_options")" \
    "${size_bytes:-0}" \
    "${available_bytes:-0}" \
    "$used_percent" \
    "$responsive" \
    "$(csv_escape "$status")" >> "$CSV"
done < <(findmnt -rn -t nfs,nfs4,cifs,smb3 -o SOURCE,TARGET,FSTYPE,OPTIONS --output-separator $'\t' 2>>"$ERRORS")

SERVER_DNS=false
NFS_PORT=false
SMB_PORT=false
EXPORT_TEST="not-requested"
SHARE_TEST="not-requested"

if [[ -n "$SERVER" ]]; then
  section "Server DNS resolution" getent ahosts "$SERVER"
  getent hosts "$SERVER" >/dev/null 2>&1 && SERVER_DNS=true
  section "Route to server" ip route get "$SERVER"

  if have nc; then
    section "NFS TCP 2049 test" nc -vz -w "$TIMEOUT_SECONDS" "$SERVER" 2049
    nc -z -w "$TIMEOUT_SECONDS" "$SERVER" 2049 >/dev/null 2>&1 && NFS_PORT=true
    section "SMB TCP 445 test" nc -vz -w "$TIMEOUT_SECONDS" "$SERVER" 445
    nc -z -w "$TIMEOUT_SECONDS" "$SERVER" 445 >/dev/null 2>&1 && SMB_PORT=true
  fi

  if have showmount; then
    EXPORT_TEST="failed"
    section "NFS exports" showmount -e "$SERVER"
    showmount -e "$SERVER" >/dev/null 2>&1 && EXPORT_TEST="passed"
  fi

  if have smbclient; then
    SHARE_TEST="failed"
    section "Anonymous SMB share enumeration" smbclient -L "//$SERVER" -N
    smbclient -L "//$SERVER" -N >/dev/null 2>&1 && SHARE_TEST="passed"
  fi
fi

OVERALL="Healthy"
if [[ "$UNRESPONSIVE_MOUNTS" -gt 0 || "$LOW_SPACE_MOUNTS" -gt 0 ]]; then
  OVERALL="Attention required"
fi

cat > "$JSON" <<EOF
{
  "collected_at": "$(date -Is)",
  "hostname": "$(hostname -f 2>/dev/null || hostname)",
  "network_mounts_detected": $TOTAL_MOUNTS,
  "responsive_mounts": $RESPONSIVE_MOUNTS,
  "unresponsive_mounts": $UNRESPONSIVE_MOUNTS,
  "mounts_over_90_percent_used": $LOW_SPACE_MOUNTS,
  "server_tested": "$SERVER",
  "server_dns_resolved": $SERVER_DNS,
  "nfs_tcp_2049_reachable": $NFS_PORT,
  "smb_tcp_445_reachable": $SMB_PORT,
  "nfs_export_test": "$EXPORT_TEST",
  "anonymous_smb_share_test": "$SHARE_TEST",
  "overall_status": "$OVERALL"
}
EOF

printf '\nNetwork mount troubleshooting completed: %s\n' "$OUTPUT_DIR" | tee -a "$REPORT"
