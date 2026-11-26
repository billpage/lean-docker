#!/usr/bin/env bash
# install.sh strix|asus : install the run_lean and lean_build tools for the Claude desktop app.
#   strix: runners = run_lean_container.sh, lean_build.sh (local docker, container "lean")
#   asus (any other LAN machine): runners = run_lean_ssh.sh, lean_build_ssh.sh (ssh to STRIX)
# Copies the files into ~/maple-connector (next to maple_mcp.py etc., reusing its venv),
# adds mcpServers.lean to ~/.config/Claude/claude_desktop_config.json (backup: .bak-lean),
# and runs one test file through the runner.
set -eu
role=${1:-}
here=$(cd "$(dirname "$0")" && pwd)
mc=$HOME/maple-connector
case $role in
    strix) runner=$mc/run_lean_container.sh; builder=$mc/lean_build.sh ;;
    asus)  runner=$mc/run_lean_ssh.sh;       builder=$mc/lean_build_ssh.sh ;;
    *)     echo "usage: $0 strix|asus" >&2; exit 2 ;;
esac
[[ -x $mc/venv/bin/python ]] || { echo "missing $mc/venv (set up for maple/sage first)" >&2; exit 1; }

install -m 755 "$here/run_lean_container.sh" "$here/run_lean_ssh.sh" \
               "$here/lean_build.sh" "$here/lean_build_ssh.sh" "$mc/"
install -m 644 "$here/lean_mcp.py" "$mc/"
mkdir -p "$HOME/lean-work/host-runs"
(cd "$mc" && sha256sum lean_mcp.py run_lean_container.sh run_lean_ssh.sh lean_build.sh \
                       lean_build_ssh.sh | cut -c1-16,65-)

cfg=$HOME/.config/Claude/claude_desktop_config.json
[[ -f $cfg ]] && cp "$cfg" "$cfg.bak-lean"
python3 - "$cfg" "$mc" "$runner" "$builder" <<'PY'
import json, os, sys
path, mc, runner, builder = sys.argv[1:]
cfg = json.load(open(path)) if os.path.exists(path) else {}
cfg.setdefault("mcpServers", {})["lean"] = {
    "command": f"{mc}/venv/bin/python",
    "args": [f"{mc}/lean_mcp.py"],
    "env": {"LEAN_RUNNER": runner, "LEAN_BUILDER": builder},
}
json.dump(cfg, open(path, "w"), indent=2)
print("desktop config mcpServers:", ", ".join(cfg["mcpServers"]))
PY

t=$HOME/lean-work/host-runs/install-test-$role
mkdir -p "$t"
printf '%s\n' 'import Mathlib.Tactic.Ring' '#eval Lean.versionString' \
    'example (x y : Int) : (x + y)^2 = x^2 + 2*x*y + y^2 := by ring' > "$t/install-test-$role.lean"
echo "--- test run via $(basename "$runner")"
"$runner" "$t/install-test-$role.lean" 300 && echo "--- runner ok" || echo "--- runner exit $?"
echo "Now restart the Claude desktop app on this machine: killall -9 claude-desktop, then reopen it."
