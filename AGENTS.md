# AGENTS.md

Context for agents working on this repository.

## What this repo is

A sandboxed environment for running [`pi-coding-agent`](https://pi.dev) inside a
container. There is no application code here — the repo *is* the environment
definition. Four parts do the work:

| File | Role |
|---|---|
| `docker/flake.nix` | Declares the toolchain, Python environment, pinned agent skill repos, and dev-shell config for the image |
| `docker/Dockerfile` | Nix-based image that pre-realises the dev shell into a profile |
| `flake.nix` | Nix flake app that runs the prebuilt container from anywhere |
| `.github/workflows/docker.yml` | Builds the image and pushes it to GHCR |

`flake.lock` and `docker/flake.lock` pin inputs and should be committed.

## Design decisions

### Nix with flakes, not a conventional base image

The image is built `FROM nixos/nix`, with `experimental-features = nix-command
flakes` written into `/etc/nix/nix.conf`. `filter-syscalls = false` is set
because Nix's sandbox otherwise fails under restrictive container runtimes.

### The dev shell is realised at build time

`docker build` runs:

```
nix develop --profile /nix/var/nix/profiles/devshell --command true
```

This pulls the whole closure into the image *and* pins it with a profile so it
survives `nix gc`. Container start-up then does no evaluation or network I/O.
The `ENTRYPOINT` runs every command through that pinned profile.

Consequence: the `shellHook` executes during `docker build`, not only on
interactive entry. Anything it writes (the `npm` install, the skills symlink)
ends up baked into an image layer.

### `/workspace` is a mount point, not a copy

There is deliberately no `COPY . .`. The flake is copied to `/opt/env`; the
project you're working on is bind-mounted at `/workspace` at runtime. Editing
`flake.nix` on the host does **nothing** until the image is rebuilt, because the
container uses the baked profile at `/opt/env`.

### Secrets are never in the flake

`OPENROUTER_API_KEY` is declared as an empty `ENV` in the `Dockerfile` and
injected at runtime. Do **not** move it into `mkShell`'s `env` block — values
there land in a world-readable `/nix/store` path.

Note the current `ENV OPENROUTER_API_KEY=""` means the variable is always
*defined but empty* rather than unset, so `${VAR:-}` checks can't distinguish
"forgot to pass it" from "passed empty".

## Build and run

### Run the prebuilt image from anywhere

The root flake exposes a launcher app. It resolves the workspace path, reads the
workspace's git identity, and runs the matching GHCR image:

```bash
nix run github:OWNER/zach-agent -- ../some-project
```

Install once to avoid re-evaluating:

```bash
nix profile install github:OWNER/zach-agent
zach-agent ../some-project
```

`OWNER` is your GitHub username or organization. The launcher defaults to
`ghcr.io/OWNER/zach-agent`, but you can override the whole reference with
`ZACH_AGENT_IMAGE`.

### Container runtime

The launcher calls `docker`, but deliberately does **not** pin it into its
`PATH` — it resolves from the caller's `PATH`, so a host `docker` that is really
a podman shim (`podman-docker`, or `virtualisation.podman.dockerCompat` on
NixOS) is used as-is.

Adding `pkgs.docker` to `makeBinPath` is actively wrong here: it shadows the
shim with a real Docker client, which then fails with a connection error because
there is no `dockerd` to talk to — Docker's CLI is only an HTTP client for its
daemon, whereas podman is daemonless. Pinning `pkgs.podman` instead would miss
the host's rootless setup (setuid helpers, `containers.conf`, subuid ranges), so
the runtime stays a host concern.

Only the flags below are used, and the shim covers them, so no podman-specific
handling is needed. Two behavioural differences are worth knowing:

- **File ownership.** Under rootless podman, container UID 0 maps to the invoking
  host user, so files the agent writes to `/workspace` come out owned by you.
  Under Docker they are root-owned on the host.
- **Named volumes are per-runtime.** Switching between docker and podman starts
  `pi-agent-home` and the uv volumes empty.

The launcher mounts and injects the same runtime state as the old Makefile:

| Flag | Purpose |
|---|---|
| `-v <workspace>:/workspace` | The project being worked on |
| `-v pi-agent-home:/root/.pi/agent` | Pi's own state (sessions, history), persists across `--rm` |
| `-v pi-agent-uv-envs:/opt/uv-envs` | Base volume for per-project uv venvs, kept out of the bind-mounted project |
| `-v pi-agent-uv-cache:/opt/uv-cache` | uv's package cache, persisted across runs |
| `-v $AGENT_KEYS:/run/agent-keys:ro` | Agent signing key, read-only (`~/.agent-keys` by default) |
| `-e UV_PROJECT_ENVIRONMENT=/opt/uv-envs/<project>` | Per-project uv venv directory, derived from workspace basename |
| `-e OPENROUTER_API_KEY` | Forwarded from the host shell (no `=`) |
| `-e GIT_AUTHOR_NAME/EMAIL` | Read from the workspace repo's git config |

Launcher environment overrides: `ZACH_AGENT_IMAGE`, `ZACH_AGENT_UV_ENV_NAME`,
`AGENT_KEYS`.

### Image versions

Each push to `main` builds and tags the image with the commit SHA. If you run
from a locked flake reference such as `github:OWNER/zach-agent`, `self.rev` is
that same SHA, so the launcher pulls the exact image built from that commit. If
you run from a dirty local tree, it falls back to `latest`.

### Build the image locally

To work on the image itself:

```bash
nix flake update --flake ./docker   # update flake.lock inputs
docker build ./docker
```

Or let GitHub Actions build and push it after you push.

Note `pi-agent-home` is distinct from `ZACH_AGENT_HOME` (`/workspace/.agent`):
the former is Pi's state in a named volume, the latter lands in your project and
should be gitignored.

## Agent skills

### How Pi finds them

Pi discovers any directory containing a `SKILL.md`, **recursively**, and honours
the Agent Skills locations `~/.agents/skills/` and `.agents/skills/`. There is
no skills-directory environment variable that Pi reads.

The `pi-skills` derivation in `docker/flake.nix` collects every pinned repo
into a single store path under its `skillSources` key. The container's
`shellHook` then symlinks that path to `~/.agents/skills/nix`. Because discovery
is recursive, a repo that bundles many skills — or nests them, as Dagster does —
can be dropped in whole.

### Adding a skill repo

Two edits. An input:

```nix
some-skills = {
  url = "github:owner/repo";
  flake = false;
};
```

...and a `skillSources` entry:

```nix
skillSources = {
  some = inputs.some-skills;
};
```

`flake = false` means "just fetch the source tree" — the repo needs no
`flake.nix`. For `github:` inputs Nix fetches a **tarball**, so there is no
`.git` directory and no history. The build fails if an input contains no
`SKILL.md` anywhere.

Only public `github:` repos are supported as written. Private repos need an
`access-tokens` entry or an SSH input, which complicates the image build
considerably.

### Currently pinned

| Key | Repo | Ref | Layout |
|---|---|---|---|
| `catalyst-cooperative` | `catalyst-cooperative/agent-skills` | default | `skills/<name>/SKILL.md` |
| `anthropic` | `anthropics/skills` | default | `document-skills/<name>/SKILL.md` etc. |
| `dagster` | `dagster-io/skills` | `release-stable` | `plugins/<plugin>/skills/<skill>/SKILL.md` |

Dagster is pinned to `release-stable` because that is what all upstream install
paths deliver; `master` carries unreleased content. Its plugin directories have
no top-level `SKILL.md`, which is why recursive discovery matters.

Updating is explicit: `nix flake update --flake ./docker dagster-skills`.

This vendors entire repos, so the agent sees every skill they contain — more
than strictly needed. This diverges from the upstream per-skill workflow
(`npx skills install owner/repo -s name`) in exchange for reproducibility.

## Git identity and commit signing

### The model

The human stays the **author**; the agent is recorded as the **committer**, with
`(aider)` suffixed to the name — aider's convention. This suits a workflow where
every change is reviewed before pushing: authorship credit is accurate, and the
committer field records which environment produced the object.

```
Author:    Zach <you@example.com>
Committer: Zach (aider) <you@example.com>
```

Identity is set through `GIT_AUTHOR_*` / `GIT_COMMITTER_*` **environment
variables**, which outrank *every* config file. A mounted repo's local
`user.name` / `user.email` therefore cannot override them.

### Where the identity comes from

The `zach-agent` launcher reads it from the host with `git -C <workspace>
config --get user.name`. Resolving *inside the workspace repo* means per-repo
overrides and `includeIf "gitdir:..."` conditional includes are honoured — point
the sandbox at a work repo and it picks up the work address automatically. The
launcher exits before starting Docker if neither config nor an explicit
override supplies a value.

### Signing key

SSH signing, not GPG — one keypair, no keyring or expiry ceremony.

Manual host-side setup, done once:

1. `mkdir -p ~/.agent-keys`
2. `ssh-keygen -t ed25519 -C "zach-agent" -f ~/.agent-keys/agent_signing`
3. Add the **public** key to GitHub as a *signing* key

The key is generated on the host and bind-mounted **read-only** at
`/run/agent-keys` (`AGENT_KEYS_DIR`). It is never generated in the container and
never baked into an image layer — during `docker build` the directory simply does
not exist, which is what skips the signing block in the `shellHook`.

The `shellHook` auto-detects a single `*.pub` in that directory; with more than
one it warns and you must set `AGENT_SIGNING_KEY` explicitly. `user.signingkey`
points at the *public* key — git asks OpenSSH for the private half by stripping
`.pub`. `openssh` is in the dev shell because git shells out to `ssh-keygen -Y
sign`; signing fails silently without it.

An `allowed_signers` file is rebuilt at `~/.ssh/allowed_signers` on every entry
(the key mount being read-only), with `namespaces="git"` to stop signatures being
replayed in another SSH context. Without it `git log --show-signature` reports an
unknown signer rather than verifying.

### Why command-scope config

Signing settings are exported as `GIT_CONFIG_COUNT` / `GIT_CONFIG_KEY_n` /
`GIT_CONFIG_VALUE_n` rather than written with `git config --global`. Git's
precedence is:

```
command scope  >  local (.git/config)  >  global  >  system
```

A `--global` setting loses to a mounted repo's local config — so a repo carrying
`commit.gpgsign = false` or `gpg.format = openpgp` would silently win. Command
scope outranks all files and is inherited by git subprocesses.

**If you add a setting, bump `GIT_CONFIG_COUNT` to match the number of indices.**

`safe.directory` is the deliberate exception and stays in `--global`:
command-scope support for it is incomplete, notably for `git clone`. It is needed
because `/workspace` is host-owned while the container runs as root.

### Security properties

Be precise about what this does and does not prove. The agent holds its own key,
so a signature proves *"produced in this sandbox"*, **not** *"authorized"* — the
agent can sign anything with that key. The real property comes from the other
half: **your own key is never mounted**, so an agent commit is provably not you.

The agent can read the private key while it is mounted; read-only prevents
modification, not exfiltration. Containment comes from this being a dedicated,
independently revocable key.

GitHub will show these commits as **Unverified** unless the key is registered to
an account whose email matches the commit. Since the commit email is the human's,
registering the agent key on the human's account yields Verified but renders the
commit as the human — partially defeating the separation. Local verification via
`allowed_signers` works regardless. A dedicated bot account is the alternative if
Verified-and-attributed matters.

Signing is **not** pushing. If the agent should push, that needs separate
credentials (a scoped deploy key or fine-grained PAT), which are deliberately not
configured here.

## Python

**Skills have no machine-readable dependency manifest.**
provides only a free-form `compatibility` string in the frontmatter (max 500
chars, advisory, nothing reads it). Dependencies must be read out of each
`SKILL.md` by hand and translated into the flake.

The current `python312.withPackages` list is maintained manually and traces to:

- `catalyst-cooperative/pudl` → `polars`, `pandas` + `s3fs`
- `anthropic/pdf` → `pypdf`, `pdfplumber`, `reportlab`, `pandas`

Plus `poppler-utils` (`pdftotext`, `pdfimages`) and `qpdf`, which the PDF skill
shells out to. `jq` and the `duckdb` CLI are also used heavily by the PUDL
skill.

If you add a skill, read its `compatibility` field and update both the package
list and the comment above it.

### Scope: toolchain vs. project deps

This Python environment is for **the agent and its skills** — a fixed set, baked
into the image, works offline. Dependencies of an arbitrary project mounted at
`/workspace` are a separate concern, handled by `uv` and `pixi` resolving at
runtime (which requires network).

For reference, the ecosystem has not standardised: `poetry2nix` is unmaintained
and its author now recommends `uv`; `mach-nix` is dead; `uv2nix` +
`pyproject.nix` is the current direction for lockfile-driven environments;
`withPackages` remains correct for small fixed sets like this one.

### `uv`

`uv` is in the dev shell for working on mounted projects, but **this image is
non-FHS** — there is no `/lib64/ld-linux-x86-64.so.2` and no `/usr/lib`. Since
`uv` works by downloading prebuilt binaries, results vary:

| Case | Works? |
|---|---|
| Pure-Python wheels | Yes |
| manylinux wheels with C extensions | Usually; fails if they need libs absent from the library path |
| `uv python install` | Blocked deliberately |

`UV_PYTHON_DOWNLOADS = "never"` is set in `env`, and `UV_PYTHON` is exported in
the `shellHook` (it needs the interpreter `PATH` actually resolves to). Without
these, `uv` fetches portable CPython builds that cannot start here — a confusing
failure mode. The consequence is that a project requesting a different Python
version fails to resolve rather than silently downloading one.

### Why not `pixi`

`pixi` was considered and **deliberately left out**. Conda-forge packages ship
their own `python` executable, which needs the FHS dynamic linker this image
lacks — and unlike `uv`, there is no `UV_PYTHON`-style redirect, because
providing the interpreter is the whole point of a conda environment. It would
also write `.pixi/` into the bind-mounted project, repeating the host-`.venv`
conflict below.

Two real fixes if conda support becomes necessary: `nix-ld` (a shim dynamic
linker written into the image) or `pkgs.buildFHSEnv` (needs user namespaces, so
likely `--privileged` — which cuts against the sandbox goal).

### The host `.venv` conflict

**A venv cannot be shared between host and container.** It hardcodes absolute
paths in at least four places: the `.venv/bin/python` symlink, `home =` in
`pyvenv.cfg`, console-script shebangs, and C extensions linked against the host
glibc. A host-created `.venv` is therefore unusable in the container, and `uv`
rejects it — even `uv lock` fails with "not a valid Python environment" when an
incompatible `.venv` is present.

The damaging direction is the agent running `uv sync`, which **deletes and
recreates** `.venv` with container paths, breaking manual development on the
host. Re-syncing on the host then breaks the container, and so on.

The fix is putting each project's venv under `/opt/uv-envs/<project>` via
`UV_PROJECT_ENVIRONMENT` — uv's documented escape hatch for exactly this
bind-mount collision. The container's venv lives outside `/workspace` entirely,
in a named volume, so host and container keep separate environments from the
same `pyproject.toml` / `uv.lock`. `UV_CACHE_DIR` is likewise moved to
`/opt/uv-cache` on a volume, so wheels are not re-fetched every run. The launcher
derives `<project>` from the workspace directory name by default, and you can
override it with `ZACH_AGENT_UV_ENV_NAME`.

Implications worth knowing:

- The agent's installed packages are **not** visible to your host tooling, and
  vice versa. Only `pyproject.toml` and `uv.lock` are shared — which is the
  correct boundary.
- Running `uv run` works, but an editor or LSP pointed at `/workspace/.venv`
  inside the container will not find anything. Use `/opt/uv-envs/<project>`.
- Each project gets a separate subdirectory under `/opt/uv-envs`, so switching
  `WORKSPACE` between projects does not clobber another project's venv. If you
  want a different name than the directory basename, set `ZACH_AGENT_UV_ENV_NAME`.


## Known issues

- **Skills live on a read-only store path.** Skills that write next to their own
  files will fail. `catalyst-cooperative/pudl` wants to populate
  `assets/cache/`. The fix is to copy skills into a writable directory rather
  than symlinking the store path.
- **`--network none` is not yet usable.** The `pudl` skill fetches from
  `s3://pudl.catalyst.coop`. The `npm install -g` bootstrap also needs network
  if `/opt/npm` is ever empty.
- **`pi-coding-agent` is installed via `npm install -g` in the `shellHook`**,
  not the vendored `buildNpmPackage`. The package output exists but has
  `lib.fakeHash` placeholders — build once and copy the real hashes from the
  error to switch over. Until then dependency resolution is not reproducible.
- **Conda/`pixi` projects are unsupported.** See "Why not `pixi`" above.
- **`HOME` must agree between build and run** for the `~/.agents/skills/nix`
  symlink to be where Pi looks. The `shellHook` falls back to `/root`, matching
  the `nixos/nix` default.

## Unverified

- Whether every Python attribute name resolves in nixpkgs (`pypdf` is the most
  likely to differ — nixpkgs historically carried `PyPDF2`). `nix develop`
  fails fast and clearly if one is wrong.
- `markitdown[pdf,docx]`, listed as optional by the PUDL skill, is probably not
  in nixpkgs and is currently omitted.
