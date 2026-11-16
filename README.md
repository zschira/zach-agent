# zach-agent

A sandboxed container for running [`pi-coding-agent`](https://pi.dev) against a
project directory. There is no application code here; the repo *is* the
environment definition.

| Path | Role |
|---|---|
| `docker/flake.nix` | Toolchain, pinned agent-skill repos, dev-shell config |
| `docker/pyproject.toml`, `docker/uv.lock` | Python deps for the agent and its skills (`/opt/agent-venv`) |
| `docker/Dockerfile` | Nix-based image that pre-realises the dev shell |
| `flake.nix` | Launcher app (`zach-agent`) that runs the prebuilt image |
| `.github/workflows/docker.yml` | Builds and pushes the image to GHCR |

See `AGENTS.md` for detailed design notes.

## How the container works

- **Nix-based image.** Built `FROM nixos/nix`. At build time the dev shell from
  `docker/flake.nix` is realised and pinned with a profile, then dumped with
  `nix print-dev-env` to `/opt/env/dev-shell-env.sh`.
- **Fast start-up.** The `ENTRYPOINT` (`/entrypoint.sh`) just sources that dump,
  so there is no flake evaluation per run. The default command is `bash -l`;
  any command you pass replaces it.
- **Toolchain.** Includes git, openssh, `uv`, `pixi`, `jq`, `duckdb`,
  `poppler-utils`, `qpdf`, and `pi-coding-agent` itself. Python for the agent
  and its skills lives in `/opt/agent-venv`.
- **Skills.** Pinned skill repos (Anthropic, Catalyst Cooperative, Dagster) are
  collected into one store path and symlinked to `~/.agents/skills/nix`, where
  Pi discovers them recursively.
- **`/workspace` is a bind mount**, not a copy. Your project is mounted there at
  runtime. Editing `flake.nix` on the host has no effect until the image is rebuilt.
- **Prebuilt binaries work** via a `nix-ld` shim at `/lib64/ld-linux-x86-64.so.2`
  (uv-managed Pythons, manylinux wheels, conda packages).
- **Per-project environments off the host tree.** uv venvs
  (`/root/.cache/uv-envs/<project>`) and pixi environments (`/root/.cache/pixi-envs`) live on named
  volumes, so the container never clobbers a host `.venv`/`.pixi`.
- **Git identity and signing.** You are the commit *author*; the agent is the
  *committer* (`Name (aider)`). Commits are SSH-signed with a dedicated key
  mounted read-only at `/run/agent-keys`. Your own key is never mounted.
- **Secrets** (`OPENROUTER_API_KEY`) are injected at runtime, never baked in.

### Volumes and mounts

| Mount | Purpose |
|---|---|
| `<workspace>:/workspace` | The project |
| `pi-agent-home:/root/.pi/agent` | Pi sessions and history |
| `pi-agent-cache:/root/.cache` | uv/pixi environments and caches, prek hook environments |
| `~/.agent-keys:/run/agent-keys:ro` | Agent signing key (optional) |

## Prerequisites

- Docker or Podman on the host.
- `OPENROUTER_API_KEY` exported in your shell.
- A git `user.name` / `user.email` configured for the workspace repo.
- Optional, for signed commits (one-time):

  ```bash
  mkdir -p ~/.agent-keys
  ssh-keygen -t ed25519 -C "zach-agent" -f ~/.agent-keys/agent_signing
  ```

  Then add the **public** key to GitHub as a *signing* key.

## Usage with the flake

```bash
# Run without installing
nix run github:zschira/zach-agent -- ../some-project

# Or install once
nix profile install github:zschira/zach-agent
zach-agent ../some-project

# Run a specific command instead of the default shell
zach-agent ../some-project pi
```

The launcher resolves the workspace path, reads the git identity from the
workspace repo (honouring per-repo config and `includeIf`), derives the uv venv
name from the directory name, and runs the matching image. When run from a locked
flake reference it pulls the image tagged with that exact commit
(`sha-<rev>`); from a dirty local tree it uses `latest`.

It calls `docker` from your `PATH` (a podman shim works).

Environment overrides:

| Variable | Effect |
|---|---|
| `ZACH_AGENT_IMAGE` | Full image reference to run |
| `ZACH_AGENT_UV_ENV_NAME` | Override the uv venv directory name |
| `AGENT_KEYS` | Directory holding the signing key (default `~/.agent-keys`) |

## Usage with docker / podman directly

Replace `docker` with `podman` as needed. Set the identity variables yourself:

```bash
IMAGE=ghcr.io/zschira/zach-agent:latest
WS=$(realpath ../some-project)

docker run --rm -it \
  -v "$WS:/workspace" \
  -v pi-agent-home:/root/.pi/agent \
  -v pi-agent-cache:/root/.cache \
  -v "$HOME/.agent-keys:/run/agent-keys:ro" \
  -e OPENROUTER_API_KEY \
  -e GIT_AUTHOR_NAME="$(git -C "$WS" config user.name)" \
  -e GIT_AUTHOR_EMAIL="$(git -C "$WS" config user.email)" \
  -e UV_PROJECT_ENVIRONMENT=/root/.cache/uv-envs/some-project \
  "$IMAGE"
```

Drop the `agent-keys` mount if you have no signing key (commits will be
unsigned). Append a command (e.g. `pi`) after `$IMAGE` to skip the shell.

On SELinux hosts (Fedora, RHEL) add `:z` or `:Z` to the bind mounts.

### Building locally

```bash
nix flake update --flake ./docker   # optional: refresh pins
docker build -f docker/Dockerfile -t zach-agent .   # context is repo root
```

The build context must be the repo root since the Dockerfile copies `AGENTS.md`.
CI does the same and pushes to GHCR on each push to `main`.

## Sandbox implications: Docker vs Podman

The container is a boundary, not a perfect jail. It has network access, and the
agent can read anything mounted in, including `/workspace` and the signing key.
The runtime changes how much a breakout or mistake can cost.

| | Docker (rootful daemon) | Rootless Podman |
|---|---|---|
| Container root maps to | Host root (unless userns-remap is set) | Your unprivileged host user |
| Escape impact | Potentially root on host | Limited to your user's privileges |
| Daemon | Root-owned `dockerd`; access to its socket is effectively root | None (daemonless) |
| Files written to `/workspace` | Owned by root on the host | Owned by you |
| Named volumes | Docker's own store | Podman's store (separate; start empty on switch) |

Practical consequences:

- **Prefer rootless Podman** for a stronger sandbox: the agent runs as "root" in
  the container but has only your user's rights on the host, and no daemon is
  involved.
- **With Docker**, the agent's root-owned files in your project may need `sudo`
  or `chown` to clean up. Never mount the Docker socket into the container.
- **In both cases**, only the workspace is writable from the host side, but the
  agent has outbound network and can read the mounted private signing key
  (use a dedicated, revocable one) and the forwarded `OPENROUTER_API_KEY`.
- The signing key proves a commit was produced in the sandbox, not that it was
  authorised. Review commits before pushing; the container has no push
  credentials.
- Switching runtimes does not carry over named volumes (`pi-agent-home`, uv/pixi
  volumes), so Pi history and caches start fresh.
