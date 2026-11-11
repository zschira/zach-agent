IMAGE ?= zach-agent

# Named volume so pi's agent state (sessions, history) persists across runs.
AGENT_VOLUME ?= pi-agent-home

# uv's venv and download cache. Kept in volumes rather than under /workspace so
# the container never touches a host-created .venv (venvs hardcode absolute
# paths and are not portable between host and container).
UV_ENV_VOLUME ?= pi-agent-uv-env
UV_CACHE_VOLUME ?= pi-agent-uv-cache

# Host directory to mount at /workspace. Required; no default, so you never
# accidentally expose this repo. `abspath` resolves relative values, since
# docker rejects relative bind-mount sources.
WORKSPACE ?=
WORKSPACE_ABS := $(abspath $(WORKSPACE))

# Host directory holding the agent's signing key, mounted read-only.
AGENT_KEYS ?= $(HOME)/.agent-keys

# Author identity, read from the host's git config as resolved *inside the
# workspace repo*, so per-repo overrides and includeIf rules are honoured.
# Deferred (?=) so git only runs for targets that reference these.
GIT_AUTHOR_NAME ?= $(shell git -C $(WORKSPACE_ABS) config --get user.name)
GIT_AUTHOR_EMAIL ?= $(shell git -C $(WORKSPACE_ABS) config --get user.email)

.PHONY: build develop lock

## Pin flake inputs; commit the resulting flake.lock.
lock:
	nix flake lock

## Build the sandbox image.
build:
	docker build -t $(IMAGE) .

## Interactive shell in the sandbox.
##   make develop WORKSPACE=../some-project
develop:
	@test -n "$(WORKSPACE)" \
		|| { echo "error: WORKSPACE is required, e.g. make develop WORKSPACE=../proj"; exit 1; }
	@test -d "$(WORKSPACE_ABS)" \
		|| { echo "error: WORKSPACE '$(WORKSPACE_ABS)' is not a directory"; exit 1; }
	@test -n "$(GIT_AUTHOR_NAME)" \
		|| { echo "error: no user.name in git config for $(WORKSPACE_ABS); set GIT_AUTHOR_NAME="; exit 1; }
	@test -n "$(GIT_AUTHOR_EMAIL)" \
		|| { echo "error: no user.email in git config for $(WORKSPACE_ABS); set GIT_AUTHOR_EMAIL="; exit 1; }
	@test -d "$(AGENT_KEYS)" \
		|| { echo "warning: $(AGENT_KEYS) missing; commits will be unsigned"; }
	docker run --rm -it \
		-v "$(WORKSPACE_ABS):/workspace" \
		-v $(AGENT_VOLUME):/root/.pi/agent \
		-v $(UV_ENV_VOLUME):/opt/uv-env \
		-v $(UV_CACHE_VOLUME):/opt/uv-cache \
		-v "$(AGENT_KEYS):/run/agent-keys:ro" \
		-e OPENROUTER_API_KEY \
		-e GIT_AUTHOR_NAME="$(GIT_AUTHOR_NAME)" \
		-e GIT_AUTHOR_EMAIL="$(GIT_AUTHOR_EMAIL)" \
		$(IMAGE)
