#!/usr/bin/env bash
# lean_build.sh: build a registered repository's Lean project (its lean/ folder) at a
# given branch or commit, in the "lean" container. Runs on the STRIX host.
#
# Usage: lean_build.sh REPO [REF [TARGET [timeout_seconds]]]
#   REPO    a clone in $LEAN_HOST_WORK/repos/REPO (made by Bill; this script never clones)
#   REF     branch on origin (default main) or a commit SHA
#   TARGET  optional lake target (default: the project's default targets)
# Exit: 0 ok, 4 ok but uses sorry, 1 build errors, 124 timeout, 2 usage / unknown ref,
#       3 not registered / no lean/ project / git or container failure / Mathlib cache mismatch.
#
# Git runs here on the host with Bill's credentials (ssh in batch mode, so it fails
# instead of prompting). The clone is checked out detached and forced to the ref: it is
# the tool's clone, so local edits in it are lost. A per-repository lock keeps two builds
# apart. If lean-toolchain or lake-manifest.json changed since the last build (or the
# packages are missing), `lake exe cache get` runs first. If the build starts compiling
# Mathlib itself, the cache does not match the pins: the build is stopped (it would take
# hours) and status 3 is returned.
set -u

repo=${1:-}
ref=${2:-main}
target=${3:-}
timeout=${4:-1800}
hostwork=${LEAN_HOST_WORK:-/var/lib/lean/work}
container=${LEAN_CONTAINER:-lean}
user=${LEAN_USER:-lean}
chome=${LEAN_CTR_HOME:-/home/lean}

if [[ ! $repo =~ ^[A-Za-z0-9._-]+$ || ! $ref =~ ^[A-Za-z0-9._/-]+$ || $ref == *..* ||
      ! $target =~ ^[A-Za-z0-9._:/-]*$ || ! $timeout =~ ^[0-9]+$ ]]; then
    echo "usage: $0 REPO [REF [TARGET [timeout_seconds]]]  (names: letters, digits, . _ - /)" >&2
    exit 2
fi
rd=$hostwork/repos/$repo
if ! git -C "$rd" rev-parse --git-dir >/dev/null 2>&1; then
    echo "repository '$repo' is not registered (no git clone in $rd)."
    printf 'registered:'
    for r in "$hostwork"/repos/*/; do [[ -d $r.git ]] && printf ' %s' "$(basename "$r")"; done
    echo; echo "Bill registers one with: git clone git@github.com:billpage/REPO.git $hostwork/repos/REPO"
    exit 3
fi
if [[ $(docker inspect -f '{{.State.Running}}' "$container" 2>/dev/null) != true ]]; then
    echo "container '$container' is not running"
    exit 3
fi

exec 9> "$(git -C "$rd" rev-parse --absolute-git-dir)/lean_build.lock"
if ! flock -w 60 9; then
    echo "another lean_build of '$repo' is still running"
    exit 3
fi

export GIT_TERMINAL_PROMPT=0 GIT_SSH_COMMAND="ssh -o BatchMode=yes -o ConnectTimeout=15"
if ! git -C "$rd" fetch --quiet --prune origin 2>&1; then
    echo "git fetch failed in $rd (credentials? network?)"
    exit 3
fi
if git -C "$rd" rev-parse --verify -q "refs/remotes/origin/$ref^{commit}" >/dev/null; then
    rev=origin/$ref
elif [[ $ref =~ ^[0-9a-f]{7,40}$ ]] && git -C "$rd" rev-parse --verify -q "$ref^{commit}" >/dev/null; then
    rev=$ref
else
    echo "unknown ref '$ref': not a branch on origin or a known commit"
    exit 2
fi
if ! git -C "$rd" checkout --quiet --detach --force "$rev" 2>&1; then
    echo "git checkout of $rev failed"
    exit 3
fi
echo "commit: $(git -C "$rd" log -1 --format='%h %s (%cs)') [$ref]"
if [[ ! -f $rd/lean/lakefile.toml && ! -f $rd/lean/lakefile.lean ]]; then
    echo "no Lean project at this commit (expected lean/lakefile.toml or lean/lakefile.lean)"
    exit 3
fi

cw=$chome/work/repos/$repo/lean
cexec() { docker exec -u "$user" -w "$cw" "$container" "$@"; }
log=$(mktemp); trap 'rm -f "$log"' EXIT
start=$SECONDS

# Mathlib cache, when the pins changed or the packages are missing
fp=$(cat "$rd/lean/lean-toolchain" "$rd/lean/lake-manifest.json" 2>/dev/null | sha256sum | cut -c1-16)
stamp=$rd/lean/.lake/lean_build.pins; mkdir -p "$rd/lean/.lake"
if grep -q '"name": *"mathlib"' "$rd/lean/lake-manifest.json" 2>/dev/null &&
   { [[ ! -d $rd/lean/.lake/packages/mathlib ]] || [[ $(cat "$stamp" 2>/dev/null) != "$fp" ]]; }; then
    echo "-- pins changed or packages missing: lake exe cache get"
    cexec timeout "$timeout" lake exe cache get 2>&1 | tr '\r' '\n' | grep -v -E '^Downloaded: |^✔ \[|^\s*$' | tail -n 15
    if [[ ${PIPESTATUS[0]} != 0 ]]; then
        echo "lake exe cache get failed"
        exit 3
    fi
    echo "$fp" > "$stamp"
fi

# The build, watched for Mathlib modules being compiled
pidf=$chome/work/runs/.lean_build.$repo.pid
cexec bash -c 'echo $$ > "$1"; exec timeout "$2" lake build ${3:+"$3"}' _ "$pidf" "$timeout" "$target" > "$log" 2>&1 &
bpid=$!
guard=0
while kill -0 "$bpid" 2>/dev/null; do
    if grep -qE '(Built|Building) Mathlib\.' "$log"; then
        guard=1
        docker exec -u "$user" "$container" bash -c 'kill -TERM -- -"$(cat "$1")" 2>/dev/null || kill -TERM "$(cat "$1")"' _ "$pidf"
        break
    fi
    sleep 2
done
wait "$bpid"; rc=$?
grep -qE '(Built|Building) Mathlib\.' "$log" && guard=1    # in case it ended between polls
[[ -f $stamp ]] || echo "$fp" > "$stamp"

# Report: everything except the per-module success lines, which are only counted.
built=$(grep -c '^✔ \[' "$log")
grep -v -e '^✔ \[' -e '^trace: ' "$log"
echo "-- $built module(s) built or replayed, $(( SECONDS - start )) s"
if (( guard )); then
    echo "STOPPED: the build started compiling Mathlib, so the Mathlib cache does not match"
    echo "this project's pins (lean-toolchain, lake-manifest.json). Check that Lean and Mathlib"
    echo "versions match (e.g. Lean v4.36.0 with Mathlib tag v4.36.0) and run lean_build again."
    exit 3
fi
sorry_n=$(grep -cF 'declaration uses `sorry`' "$log")
case $rc in
    0) (( sorry_n )) && { echo "[uses sorry: $sorry_n warning(s)]"; rc=4; } ;;
    124) echo "[timed out after ${timeout}s]" ;;
    125|126|127) rc=3 ;;
    *) rc=1 ;;
esac
exit $rc
