# Lean 4 + Mathlib container on STRIX. See README.md.
SHELL := /bin/bash
.SHELLFLAGS := -o pipefail -c

TAG       ?= $(shell date +%Y%m%d)
IMAGE     ?= lean-env:$(TAG)
RUNIMAGE  ?= lean-env:latest
NAME      ?= lean
MEMORY    ?= 12g
TOOLCHAIN ?= leanprover/lean4:v4.36.0
# On STRIX's NVMe root disk: /home is btrfs RAID1 on spinning disks, where a cold
# `import Mathlib` took ~10 minutes (random reads of ~9,100 .olean files).
LEANROOT  ?= /var/lib/lean
HOMEDIR   ?= $(LEANROOT)/home
WORK      ?= $(LEANROOT)/work

.PHONY: build run stop restart init check shell status

# Each build is tagged lean-env:<date> and lean-env:latest; `run` starts latest. A rebuild
# on the same day keeps the replaced image as <date>-prev (rollback: make restart RUNIMAGE=...).
build:
	@if docker image inspect $(IMAGE) >/dev/null 2>&1; then docker tag $(IMAGE) $(IMAGE)-prev; fi
	docker build --build-arg UID=$$(id -u) --build-arg GID=$$(id -g) \
	  --progress=plain -t $(IMAGE) . 2>&1 | tee build-$(TAG).log
	docker tag $(IMAGE) lean-env:latest

run:
	@test -w $(LEANROOT) || { echo "$(LEANROOT) is missing or not writable; run: sudo mkdir -p $(LEANROOT) && sudo chown $$(id -un): $(LEANROOT)" >&2; exit 2; }
	mkdir -p $(HOMEDIR) $(WORK)/runs $(WORK)/host-runs $(WORK)/repos
	docker run -d --name $(NAME) --hostname $(NAME) --restart unless-stopped \
	  --memory $(MEMORY) \
	  -v $(HOMEDIR):/home/lean -v $(WORK):/home/lean/work \
	  $(RUNIMAGE)

stop:
	-docker stop $(NAME)
	-docker rm $(NAME)

restart: stop run

# elan + toolchain + scratch project with the Mathlib cache (idempotent; first run downloads ~4 GB)
init:
	docker exec -e LEAN_TOOLCHAIN=$(TOOLCHAIN) $(NAME) lean-init

check:
	docker exec $(NAME) lean-check

shell:
	docker exec -it $(NAME) bash

status:
	docker ps -a --filter name=^/$(NAME)$$
	docker images lean-env
	-docker exec $(NAME) bash -c 'elan toolchain list; du -sh ~/.elan ~/.cache/mathlib ~/work/scratch/.lake 2>/dev/null'
