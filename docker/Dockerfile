# syntax=docker/dockerfile:1

# Nix (NixOS's package manager) on a minimal base, used as the sandbox runtime.
FROM nixos/nix:2.35.6

# Enable flakes + the unified `nix` CLI.
# filter-syscalls=false keeps builds working under restrictive container runtimes.
RUN mkdir -p /etc/nix \
 && printf '%s\n' \
      'experimental-features = nix-command flakes' \
      'filter-syscalls = false' \
      'warn-dirty = false' \
      'max-jobs = auto' \
      >> /etc/nix/nix.conf

# Expose the CA bundle at the conventional FHS path. nixos/nix only ships it
# under /nix/var/nix/profiles/default and sets SSL_CERT_FILE, which tools with
# their own TLS stack (e.g. DuckDB's extension installer, used by PUDL's test
# conftest) ignore - they fail with "Problem with the SSL CA cert".
RUN mkdir -p /etc/ssl/certs \
 && ln -sf /nix/var/nix/profiles/default/etc/ssl/certs/ca-bundle.crt \
      /etc/ssl/certs/ca-certificates.crt

ENV NIX_CONFIG="experimental-features = nix-command flakes"
ENV LANG=C.UTF-8
ENV SHELL=/bin/bash
# Container has no clipboard tool; make pi emit OSC 52 so the host terminal gets the copy
ENV PI_CLIPBOARD_OSC52=1

# The flake lives here; the actual project is bind-mounted at /workspace.
WORKDIR /opt/env
COPY docker/flake.nix ./
COPY docker/flake.lock ./
# Copy sandbox instructions into the image so they can be installed into the
# agent config directory on every container start.
COPY AGENTS.md ./

# Realise the dev shell closure and pin it with a profile so it survives `nix gc`
# and so container start-up does no network/eval work.
RUN nix develop --profile /nix/var/nix/profiles/devshell --command true \
 && nix print-dev-env > /opt/env/dev-shell-env.sh

WORKDIR /workspace

# Declared, not populated: the real value is injected at runtime so it never
# ends up in an image layer or in /nix/store.
ENV OPENROUTER_API_KEY=""

# Load the pre-computed dev-shell environment instead of invoking `nix develop`
# at runtime. This avoids per-start flake evaluation and store realisation.
#
# Notes, each of which caused a real failure:
# - nixos/nix has no /bin/bash (only /bin/sh -> bash), so a `#!/bin/bash`
#   shebang fails with "No such file or directory". Symlink it.
# - The devshell profile is a JSON env file, not a directory with bin/.
# - print-dev-env output already ends with `eval "$shellHook"`; don't re-run.
# - The shellHook runs `set -- *.pub`, clobbering positional args, so the
#   command is saved before sourcing.
# - No `set -euo pipefail`: `nix develop` doesn't run hooks under it either.
RUN ln -sf "$(readlink -f /bin/sh)" /bin/bash \
 && printf '%s\n' \
    '#!/bin/bash' \
    'cmd=("$@")' \
    'set --' \
    'source /opt/env/dev-shell-env.sh' \
    'exec "${cmd[@]}"' \
    > /entrypoint.sh \
 && chmod +x /entrypoint.sh \
 && /entrypoint.sh true

# Copied late so editing Python deps doesn't invalidate the nix layers above.
COPY docker/pyproject.toml docker/uv.lock /opt/env/agent-env/

# Build the agent/skills venv. Runs through the entrypoint so uv and the nix-ld
# shim are available. UV_PROJECT_ENVIRONMENT is overridden because the dev shell
# defaults it to a per-project path on a runtime volume; /opt/agent-venv must
# stay in the image. The managed interpreter goes to UV_PYTHON_INSTALL_DIR
# (/opt/uv-python, set by the flake), which the venv's python symlinks into.
# --no-cache keeps wheels out of the layer. The final import is a smoke test:
# a manylinux wheel missing a library fails at import, not at install.
RUN /entrypoint.sh env UV_PROJECT_ENVIRONMENT=/opt/agent-venv \
      uv sync --frozen --no-cache --project /opt/env/agent-env \
 && /entrypoint.sh python3 -c "import polars, pandas, s3fs, pyarrow, requests, pypdf, pdfplumber, reportlab"

# Pre-build pixi environments for the PUDL repos (main branch). Pixi detached
# environments are named <project>-<hash of project path>, and conda prefixes
# are not relocatable, so each repo is cloned at /workspace (where it will be
# mounted at runtime) and installed under /root/.cache/pixi-envs (where the
# cache volume will mount). The finished environments are then moved to
# /opt/pixi-envs-seed, since a volume mounted over /root/.cache would hide
# them; the shellHook copies them back into the volume on first start.
# --frozen installs exactly what pixi.lock says. Editable installs of the
# projects point at /workspace/src, so they resolve once the repo is mounted.
RUN /entrypoint.sh bash -euc ' \
      export PIXI_CACHE_DIR=/tmp/pixi-cache; \
      for spec in "pudl:dev" "pudl-archiver:default"; do \
        repo=${spec%%:*}; envs=${spec#*:}; \
        git clone --depth 1 --branch main "https://github.com/catalyst-cooperative/$repo" /tmp/src; \
        cp -a /tmp/src/. /workspace/; rm -rf /tmp/src; \
        (cd /workspace && pixi install --frozen -e "$envs"); \
        find /workspace -mindepth 1 -maxdepth 1 -exec rm -rf {} +; \
      done; \
      rm -rf /tmp/pixi-cache; \
      mkdir -p /opt/pixi-envs-seed; \
      mv /root/.cache/pixi-envs/* /opt/pixi-envs-seed/; \
      ls /opt/pixi-envs-seed'

ENTRYPOINT ["/entrypoint.sh"]
CMD ["pi"]

