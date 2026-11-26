#!/usr/bin/env bash
# lean_build_ssh.sh: run lean_build.sh on STRIX from another LAN machine, over ssh.
# Usage and exit codes as lean_build.sh: REPO [REF [TARGET [timeout_seconds]]]; a failed
# ssh gives 3. Overrides: LEAN_SSH_HOST (wspage@192.168.4.73), LEAN_SSH_PORT (22),
# LEAN_REMOTE_BUILDER (~/maple-connector/lean_build.sh).
set -u
repo=${1:-}; ref=${2:-main}; target=${3:-}; timeout=${4:-1800}
if [[ ! $repo =~ ^[A-Za-z0-9._-]+$ || ! $ref =~ ^[A-Za-z0-9._/-]+$ || $ref == *..* ||
      ! $target =~ ^[A-Za-z0-9._:/-]*$ || ! $timeout =~ ^[0-9]+$ ]]; then
    echo "usage: $0 REPO [REF [TARGET [timeout_seconds]]]" >&2
    exit 2
fi
host=${LEAN_SSH_HOST:-wspage@192.168.4.73}
port=${LEAN_SSH_PORT:-22}
builder=${LEAN_REMOTE_BUILDER:-'~/maple-connector/lean_build.sh'}
ssh -4 -T -p "$port" -o BatchMode=yes -o ConnectTimeout=10 "$host" \
    "$builder $(printf '%q ' "$repo" "$ref" "$target" "$timeout")" < /dev/null 2>&1
rc=$?
case $rc in
    0|1|2|3|4|124) exit $rc ;;
    *)             exit 3 ;;
esac
