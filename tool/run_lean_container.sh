#!/usr/bin/env bash
# run_lean_container.sh: check one Lean file in the local "lean" Docker container.
#
# Usage: run_lean_container.sh DIR/STEM.lean [timeout_seconds]
# Environment:
#   LEAN_PROJECT    scratch (default) | <repo>   (a clone in ~/work/repos/<repo>, project in lean/)
#   LEAN_CONTAINER (lean), LEAN_USER (lean), LEAN_CTR_HOME (/home/lean)
# Writes DIR/STEM.out (cleaned) and DIR/STEM.log (raw).
# Exit: 0 ok, 4 ok but uses sorry, 1 Lean errors, 124 timeout, 2 usage,
#       3 container not running / project missing or not built / docker failure.
#
# The file goes into the container as a tar stream on stdin (so the MCP stream is never
# read), lands in ~/work/runs/STEM/ and is checked with `lake env lean` inside the
# project, so it can import Mathlib and, for a repository, that project's own modules
# (as of its last lean_build).
set -u

file=${1:-}
timeout=${2:-300}
if [[ -z $file || ! -f $file || $file != *.lean || ! $timeout =~ ^[0-9]+$ ]]; then
    echo "usage: $0 DIR/STEM.lean [timeout_seconds]" >&2
    exit 2
fi
container=${LEAN_CONTAINER:-lean}
user=${LEAN_USER:-lean}
chome=${LEAN_CTR_HOME:-/home/lean}
project=${LEAN_PROJECT:-scratch}
dir=$(cd "$(dirname "$file")" && pwd)
stem=$(basename "$file" .lean)
out=$dir/$stem.out
log=$dir/$stem.log

if [[ ! $project =~ ^[A-Za-z0-9._-]+$ || ! $stem =~ ^[A-Za-z0-9._-]+$ ]]; then
    echo "bad LEAN_PROJECT or file name (letters, digits, . _ - only)" | tee "$out" >&2
    exit 2
fi
if [[ $(docker inspect -f '{{.State.Running}}' "$container" 2>/dev/null) != true ]]; then
    echo "container '$container' is not running" | tee "$out" >&2
    exit 3
fi

# $1 stem, $2 timeout, $3 project
tar -cf - -C "$dir" "$stem.lean" |
docker exec -i -u "$user" -w "$chome/work" "$container" bash -c '
    if [ "$3" = scratch ]; then pd=$HOME/work/scratch; else pd=$HOME/work/repos/$3/lean; fi
    if [ ! -f "$pd/lakefile.toml" ] && [ ! -f "$pd/lakefile.lean" ]; then
        echo "project \"$3\" not found (no lakefile in ${pd#$HOME/})."
        printf "available: scratch"
        for r in "$HOME"/work/repos/*/lean; do
            [ -f "$r/lakefile.toml" ] || [ -f "$r/lakefile.lean" ] || continue
            r=${r%/lean}; printf " %s" "${r##*/}"
        done; echo
        exit 3
    fi
    if [ ! -d "$pd/.lake" ]; then
        echo "project \"$3\" has not been built yet: run lean_build first."
        exit 3
    fi
    d=$HOME/work/runs/$1
    mkdir -p "$d" && tar -xf - -C "$d" || exit 3
    cd "$pd" || exit 3
    exec timeout "$2" lake env lean "$d/$1.lean"
' _ "$stem" "$timeout" "$project" > "$log" 2>&1
rc=$?

# Shorten ".../runs/STEM/STEM.lean:L:C: " to "L:C: " and count the sorry warnings.
sed "s|$chome/work/runs/$stem/$stem\.lean:||g" "$log" > "$out"
sorry_lines=$(grep -F 'declaration uses `sorry`' "$out" | cut -d: -f1 | paste -sd, -)

case $rc in
    0|1|3|124) ;;
    125|126|127) rc=3 ;;
    *) echo "[lean exited with status $rc]" >> "$out"; rc=1 ;;
esac
if [[ $rc == 0 && -n $sorry_lines ]]; then
    echo "[uses sorry: line(s) $sorry_lines]" >> "$out"
    rc=4
fi
[[ $rc == 124 ]] && echo "[timed out after ${timeout}s]" >> "$out"
cat "$out"
exit $rc
