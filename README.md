# lean-docker (STRIX)

Lean 4 and Mathlib in a container on STRIX, shared by all of Bill's repositories. Each
repository keeps its Lean project in a `lean/` folder. Plan and decisions: Compute
project doc `claude/strix-lean-container-plan.md`.

| Path on host | In container | What |
|---|---|---|
| (image) | — | ubuntu:24.04 + git, curl; user `lean` with wspage's UID/GID; `lean-init`, `lean-check` |
| `~/lean-home` | `/home/lean` | `.elan/` (elan + toolchains, ~3 GB each), `.cache/mathlib/` (downloaded `.ltar`, ~0.5 GB per Mathlib version) |
| `~/lean-work` | `/home/lean/work` | `scratch/` (Mathlib project), `repos/<repo>/` (clones; git on host), `runs/`, `host-runs/` |

The image holds no Lean: everything Lean downloads lives in `~/lean-home`, so rebuilding
the image never downloads anything again. Each project unpacks its own copy of Mathlib
under `lean/.lake/packages` (~7 GB).

## Build and start

```bash
cd ~/lean-docker
make build          # small image, tagged lean-env:<date>; the old one keeps a -prev tag
make run            # container "lean", restart unless-stopped, --memory 12g, no ports
make init           # elan, Lean v4.36.0, ~/lean-work/scratch with Mathlib v4.36.0 (first run ~4 GB)
make check          # versions; field_simp, ring, norm_num; #print axioms; sorry detection; timings
make status         # container, images, toolchains and disk use
```

Variables: `TOOLCHAIN` (`leanprover/lean4:v4.36.0`), `MEMORY` (`12g`), `TAG`, `IMAGE`,
`HOMEDIR`, `WORK`. `make init` is idempotent.

## Pins

Lean **v4.36.0**, Mathlib tag **v4.36.0**. `lake +leanprover/lean4:v4.36.0 new <name> math`
pins Mathlib to the matching tag by itself and downloads the cache from
`https://cache.mathlib.org`. The cache only matches when Lean and Mathlib match exactly, so
never run a bare `lake update` in a project; change both pins together, on purpose.

## Repositories

Git happens on the host. To make a repository available to the container:

```bash
git clone git@github.com:billpage/<repo>.git ~/lean-work/repos/<repo>
docker exec -w /home/lean/work/repos/<repo>/lean lean bash -lc 'lake exe cache get && lake build'
```

A new Lean project in a repository: `docker exec -w /home/lean/work/repos/<repo> lean lake +leanprover/lean4:v4.36.0 new lean math`
(creates `<repo>/lean/`; commit it from the host).

## Notes (measured 2026-11-26 in a 2-core Claude workspace; STRIX should be faster)

- `import Mathlib` takes ~20 s and ~5 GB resident (mostly memory-mapped `.olean` files).
  Narrow imports are much cheaper: `Mathlib.Tactic.FieldSimp`, `Mathlib.Tactic.Ring` and
  `Mathlib.Algebra.Field.Rat` take ~3.5 s and 1.7 GB.
- A file with `sorry` compiles with exit status 0 and the warning
  ``declaration uses `sorry` `` (with backticks). Tools must check for it.
- `#print axioms T` should list only `propext`, `Classical.choice`, `Quot.sound`.
