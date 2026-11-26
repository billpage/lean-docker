#!/usr/bin/env python3
"""lean_mcp.py: lets claude.ai chats run Lean 4 + Mathlib on Bill's STRIX server.

Two tools:
  run_lean(code, name, timeout, project)  saves the code as
      ~/lean-work/host-runs/<stamp>-<name>/<stamp>-<name>.lean on this machine and checks it
      with LEAN_RUNNER (run_lean_container.sh on STRIX, run_lean_ssh.sh elsewhere).
  lean_build(repo, ref, target, timeout)  builds a registered repository's lean/ project at
      a branch or commit with LEAN_BUILDER (lean_build.sh on STRIX, lean_build_ssh.sh
      elsewhere); the output is saved under ~/lean-work/host-runs/<stamp>-build-<repo>/.

Started by the Claude desktop app as a local stdio MCP server:
    python3 lean_mcp.py
Uses the same venv as maple_mcp.py, sage_mcp.py and fricas_mcp.py (MCP Python SDK 2.x).
"""
import os
import pathlib
import re
import subprocess
import time

from mcp.server.mcpserver import MCPServer

RUNNER = os.path.expanduser(
    os.environ.get("LEAN_RUNNER", "~/maple-connector/run_lean_container.sh"))
BUILDER = os.path.expanduser(
    os.environ.get("LEAN_BUILDER", "~/maple-connector/lean_build.sh"))
RUNS = pathlib.Path(os.path.expanduser(
    os.environ.get("LEAN_RUNS", "~/lean-work/host-runs")))
MAX_TIMEOUT = 3600        # seconds
MAX_OUTPUT = 100_000      # characters returned to the chat
NAME_RE = r"[A-Za-z0-9._-]+"

STATUS = {0: "ok",
          4: "compiles, but uses sorry (NOT a finished proof)",
          1: "Lean reported errors",
          2: "usage error",
          3: "not available (container, project, git, or Mathlib cache problem; see output)"}

server = MCPServer(
    "lean",
    instructions=(
        "Lean 4.36.0 with Mathlib v4.36.0 in a Docker container on STRIX. run_lean checks "
        "one file with `lake env lean` (each call a fresh process; no REPL state): in "
        "project 'scratch' it can import any Mathlib module; with a repository name it can "
        "also import that repository's own modules as of its last lean_build. Prefer narrow "
        "imports (e.g. Mathlib.Tactic.Ring, Mathlib.Tactic.FieldSimp, "
        "Mathlib.Algebra.Field.Rat: ~5 s) over `import Mathlib` (~20 s). Messages are "
        "line:col: severity: text; a failed proof shows the remaining goals in its error. "
        "Status 4 means the file compiles but contains sorry: it is not a proof. To confirm "
        "a finished theorem, add `#print axioms T`: it should list only propext, "
        "Classical.choice and Quot.sound. lean_build builds a repository's lean/ folder at a "
        "pushed branch or commit (Bill registers repositories by cloning them on STRIX); "
        "push the branch first. Never `lake update` a project: Lean and Mathlib pins change "
        "together, on purpose."),
)


def _rundir(label: str) -> pathlib.Path:
    label = "".join(c if c.isalnum() or c in "-_" else "_" for c in label)[:40] or "run"
    stem = f"{time.strftime('%Y%m%d-%H%M%S')}-{label}"
    rundir, n = RUNS / stem, 1
    while rundir.exists():            # two runs in the same second
        n += 1
        rundir = RUNS / f"{stem}-{n}"
    rundir.mkdir(parents=True)
    return rundir


def _call(argv, cwd, timeout, env=None):
    try:
        # stdin=DEVNULL: our stdin is the MCP stream; the runner must never read it.
        p = subprocess.run(argv, cwd=cwd, env=env, stdin=subprocess.DEVNULL,
                           capture_output=True, text=True, timeout=timeout + 120)
        out = p.stdout + (f"\n[stderr]\n{p.stderr}" if p.stderr.strip() else "")
        return p.returncode, out
    except subprocess.TimeoutExpired:
        return 124, ""


def _status(rc, timeout):
    return f"timed out after {timeout}s" if rc == 124 else STATUS.get(rc, f"exit code {rc}")


def _clip(out, saved):
    if len(out) > MAX_OUTPUT:
        out = out[:MAX_OUTPUT] + f"\n[truncated; full output in {saved}]"
    return out


@server.tool()
def run_lean(code: str, name: str = "run", timeout: int = 300,
             project: str = "scratch") -> str:
    """Check a Lean 4 file (with Mathlib available) on Bill's server.

    code: the complete file, including its imports (e.g. `import Mathlib.Tactic.Ring`).
          #eval, #check, #print axioms output is returned.
    name: short label used in the saved file names.
    timeout: seconds before the run is killed (max 3600).
    project: 'scratch' (Mathlib only) or a registered repository name, whose lean/
             project's modules can then be imported.

    Returns a status line (ok / compiles, but uses sorry / Lean reported errors / ...),
    the saved file path, and Lean's messages as line:col: severity: text.
    """
    if not re.fullmatch(NAME_RE, project or ""):
        return "status: bad project name (letters, digits, . _ - only)"
    rundir = _rundir(name)
    src = rundir / f"{rundir.name}.lean"
    src.write_text(code if code.endswith("\n") else code + "\n")
    timeout = max(1, min(int(timeout), MAX_TIMEOUT))
    rc, out = _call([RUNNER, str(src), str(timeout)], rundir, timeout,
                    env=dict(os.environ, LEAN_PROJECT=project))
    return (f"status: {_status(rc, timeout)}\nproject: {project}\nfile: {src}\n---\n"
            f"{_clip(out, src.with_suffix('.out'))}")


@server.tool()
def lean_build(repo: str, ref: str = "main", target: str = "",
               timeout: int = 1800) -> str:
    """Build a registered repository's Lean project (its lean/ folder) on Bill's server.

    repo: repository name, e.g. 'fricas-symbolic' (must be registered on STRIX).
    ref: a branch pushed to GitHub (default 'main') or a commit SHA.
    target: optional lake target (module or library); default: the project's defaults.
    timeout: seconds before the build is killed (max 3600).

    Fetches, checks out the ref, refreshes the Mathlib cache if the pins changed, and runs
    `lake build`. Returns a status line, the commit built, and the build messages
    (per-module success lines are only counted). A build that starts compiling Mathlib
    itself is stopped: the pins do not match the cache.
    """
    if not re.fullmatch(NAME_RE, repo or ""):
        return "status: bad repo name (letters, digits, . _ - only)"
    if not re.fullmatch(r"[A-Za-z0-9._/-]+", ref or "") or ".." in ref:
        return "status: bad ref"
    if not re.fullmatch(r"[A-Za-z0-9._:/-]*", target or ""):
        return "status: bad target"
    timeout = max(1, min(int(timeout), MAX_TIMEOUT))
    rundir = _rundir(f"build-{repo}")
    rc, out = _call([BUILDER, repo, ref, target, str(timeout)], rundir, timeout)
    saved = rundir / "build.out"
    saved.write_text(out)
    return (f"status: {_status(rc, timeout)}\nrepo: {repo}, ref: {ref}"
            f"{', target: ' + target if target else ''}\nlog: {saved}\n---\n"
            f"{_clip(out, saved)}")


if __name__ == "__main__":
    server.run("stdio")
