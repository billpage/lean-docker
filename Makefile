# Lean 4 + Mathlib container on STRIX. See README.md.
SHELL := /bin/bash
.SHELLFLAGS := -o pipefail -c

TAG       ?= $(shell date +%Y%m%d)
IMAGE     ?= lean-env:$(TAG)
NAME      ?= lean
MEMORY    ?= 12g
TOOLCHAIN ?= leanprover/lean4:v4.36.0
HOMEDIR   ?= $(HOME)/lean-home
WORK      ?= $(HOME)/lean-work

.PHONY: build run stop restart init check shell status

# The image being replaced keeps a "-prev" tag, for rollback (make restart IMAGE=...-prev).
build:
	-docker image inspect $(IMAGE) >/dev/null 2>&1 && docker tag $(IMAGE) $(IMAGE)-prev
	docker build --build-arg UID=$$(id -u) --build-arg GID=$$(id -g) \
	  --progress=plain -t $(IMAGE) . 2>&1 | tee build-$(TAG).log

run:
	mkdir -p $(HOMEDIR) $(WORK)/runs $(WORK)/host-runs $(WORK)/repos
	docker run -d --name $(NAME) --hostname $(NAME) --restart unless-stopped \
	  --memory $(MEMORY) \
	  -v $(HOMEDIR):/home/lean -v $(WORK):/home/lean/work \
	  $(IMAGE)

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
