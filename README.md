# lean-docker (STRIX)

Lean 4 and Mathlib in a container on STRIX, shared by all of Bill's repositories. Each
repository keeps its Lean project in a `lean/` folder. Plan and decisions: Compute
project doc `claude/strix-lean-container-plan.md`.

| Path on host | In container | What |
|---|---|---|
| (image) | — | ubuntu:24.04 + git, curl; user `lean` with wspage's UID/GID; `lean-init`, `lean-check` |
| `/var/lib/lean/home` (`~/lean-home`) | `/home/lean` | `.elan/` (elan + toolchains, ~3 GB each), `.cache/mathlib/` (downloaded `.ltar`, ~0.5 GB per Mathlib version) |
| `/var/lib/lean/work` (`~/lean-work`) | `/home/lean/work` | `scratch/` (Mathlib project), `repos/<repo>/` (clones; git on host), `runs/`, `host-runs/` |

The image holds no Lean: everything Lean downloads lives in `/var/lib/lean/home`, so
rebuilding the image never downloads anything again. `/var/lib/lean` is on STRIX's NVMe root
disk, not on `/home` (btrfs RAID1 on spinning disks): a cold `import Mathlib` reads ~5 GB
scattered over ~9,100 `.olean` files, which took almost 10 minutes from `/home`.
`~/lean-home` and `~/lean-work` are symlinks to the NVMe directories. Each project unpacks
its own copy of Mathlib under `lean/.lake/packages` (~7 GB).

## Build and start

```bash
sudo mkdir -p /var/lib/lean && sudo chown wspage: /var/lib/lean      # once
ln -s /var/lib/lean/home ~/lean-home && ln -s /var/lib/lean/work ~/lean-work
cd ~/lean-docker
make build          # small image, tagged lean-env:<date> and lean-env:latest
make run            # container "lean" from lean-env:latest, restart unless-stopped, --memory 12g
make init           # elan, Lean v4.36.0, ~/lean-work/scratch with Mathlib v4.36.0 (first run ~4 GB)
make check          # versions; field_simp, ring, norm_num; #print axioms; sorry detection; timings
make status         # container, images, toolchains and disk use
```

Variables: `TOOLCHAIN` (`leanprover/lean4:v4.36.0`), `MEMORY` (`12g`), `LEANROOT`
(`/var/lib/lean`), `HOMEDIR`, `WORK`, `TAG`, `IMAGE`, `RUNIMAGE` (`lean-env:latest`).
`make init` is idempotent. Rollback to an older image: `make restart RUNIMAGE=lean-env:<tag>`.

## Pins

Lean **v4.36.0**, Mathlib tag **v4.36.0**. `lake +leanprover/lean4:v4.36.0 new <name> math`
pins Mathlib to the matching tag by itself and downloads the cache from
`https://cache.mathlib.org`. The cache only matches when Lean and Mathlib match exactly, so
never run a bare `lake update` in a project; change both pins together, on purpose.

## Repositories

Git happens on the host. To register a repository with the tools, clone it once:

```bash
git clone git@github.com:billpage/<repo>.git /var/lib/lean/work/repos/<repo>
```

The tools never clone anything, and `lean_build` treats the clone as its own: it checks
out the requested ref detached and forced, so don't keep local edits there.

A repository without a Lean project gets one with
`docker exec -w /home/lean/work/repos/<repo> lean lake +leanprover/lean4:v4.36.0 new lean math`
(creates `<repo>/lean/`; commit it from the host or from Claude's own clone). The `math`
template switches on Mathlib's style linters (`weak.linter.mathlibStandardSet = true` in
`lakefile.toml`), which ask every file for a copyright header and a module doc-string;
delete that line unless the project should follow Mathlib's style.

## Claude tools (`tool/`)

`tool/install.sh strix` (on STRIX) or `tool/install.sh asus` (other machines; ssh to STRIX)
copies the tool into `~/maple-connector`, next to the Maple, Sage and FriCAS tools, adds
`mcpServers.lean` to the Claude desktop config (backup `.bak-lean`) and runs one test file.
Then restart the desktop app.

| Tool | What it does |
|---|---|
| `run_lean(code, name="run", timeout=300, project="scratch")` | checks one file with `lake env lean`, in `scratch` or in a registered repository's `lean/` project (which lets it import that project's modules, as of its last build) |
| `lean_build(repo, ref="main", target="", timeout=1800)` | fetches, checks out the branch or commit, runs `lake exe cache get` if the pins changed, then `lake build`; reports the commit and the messages |

| Status | Meaning |
|---|---|
| 0 | ok |
| 4 | compiles, but uses `sorry`: not a finished proof |
| 1 | Lean errors (`line:col: error: …`, with the remaining goals) |
| 124 | timeout |
| 2 | usage error, or (`lean_build`) unknown ref |
| 3 | container not running, project not registered or not built, git fetch failed, or the build started compiling Mathlib (cache doesn't match the pins; stopped) |

Files: `run_lean_container.sh` and `lean_build.sh` (STRIX), `run_lean_ssh.sh` and
`lean_build_ssh.sh` (other machines), `lean_mcp.py` (MCP Python SDK 2.x, the venv of
`~/maple-connector`). Runs are saved under `~/lean-work/host-runs/`.

`lean_build` fetches with ssh in batch mode, so on STRIX the key for GitHub must work
without a passphrase prompt (as it must for any non-interactive git). If it doesn't, the
tool returns status 3 with "git fetch failed".

## Notes

Timings of `make check` (narrow imports / `import Mathlib`):

| Where | narrow | full |
|---|---|---|
| Claude workspace, 2 cores, warm | 3.4–6 s | ~20 s |
| STRIX, `/home` (HDD RAID1), cold, right after `make init` | 52 s | 588 s |
| STRIX, `/home`, warm | 5.3 s | 27.7 s |
| STRIX, NVMe, cold (`drop_caches`) | 7.9 s | 17.2 s |

Other measurements (2-core Claude workspace, 2026-11-26):

- `import Mathlib` takes ~20 s and ~5 GB resident (mostly memory-mapped `.olean` files).
  Narrow imports are much cheaper: `Mathlib.Tactic.FieldSimp`, `Mathlib.Tactic.Ring` and
  `Mathlib.Algebra.Field.Rat` take ~3.5 s and 1.7 GB.
- A file with `sorry` compiles with exit status 0 and the warning
  ``declaration uses `sorry` `` (with backticks). Tools must check for it.
- `#print axioms T` should list only `propext`, `Classical.choice`, `Quot.sound`.
