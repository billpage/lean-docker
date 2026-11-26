#!/usr/bin/env bash
# run_lean_ssh.sh: check one Lean file in the "lean" container on STRIX from another LAN
# machine, by ssh to the STRIX host and its run_lean_container.sh.
#
# Usage: run_lean_ssh.sh DIR/STEM.lean [timeout_seconds]
# Writes DIR/STEM.out (the cleaned output returned by STRIX). Exit codes as the container
# runner (0, 4, 1, 124, 2, 3); a failed ssh gives 3.
#
# The file goes over ssh as a tar stream to STRIX ~/lean-work/host-runs/<host>-STEM/,
# then STRIX's container runner takes over. LEAN_PROJECT is passed along (ssh does not
# forward the environment).
# Overrides: LEAN_SSH_HOST (wspage@192.168.4.73), LEAN_SSH_PORT (22),
#            LEAN_REMOTE_RUNNER (~/maple-connector/run_lean_container.sh).
set -u

file=${1:-}
timeout=${2:-300}
if [[ -z $file || ! -f $file || $file != *.lean || ! $timeout =~ ^[0-9]+$ ]]; then
    echo "usage: $0 DIR/STEM.lean [timeout_seconds]" >&2
    exit 2
fi
project=${LEAN_PROJECT:-scratch}
if [[ ! $project =~ ^[A-Za-z0-9._-]+$ ]]; then
    echo "bad LEAN_PROJECT" >&2
    exit 2
fi
host=${LEAN_SSH_HOST:-wspage@192.168.4.73}
port=${LEAN_SSH_PORT:-22}
runner=${LEAN_REMOTE_RUNNER:-'~/maple-connector/run_lean_container.sh'}
dir=$(cd "$(dirname "$file")" && pwd)
stem=$(basename "$file" .lean)
rstem="$(hostname -s)-$stem"
out=$dir/$stem.out

remote='d=~/lean-work/host-runs/$1; mkdir -p "$d" && tar -xf - -C "$d" || exit 3
LEAN_PROJECT=$3 exec '"$runner"' "$d/$1.lean" "$2"'
tar -cf - -C "$dir" --transform "s|^$stem\\.|$rstem.|" "$stem.lean" |
ssh -4 -T -p "$port" -o BatchMode=yes -o ConnectTimeout=10 "$host" \
    "bash -c $(printf %q "$remote") _ $(printf %q "$rstem") $timeout $project" \
    > "$out" 2>&1
rc=$?

cat "$out"
case $rc in
    0|1|2|3|4|124) exit $rc ;;
    *)             exit 3 ;;      # 255 = ssh itself failed
esac
