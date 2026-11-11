# syntax=docker/dockerfile:1

# Nix (NixOS's package manager) on a minimal base, used as the sandbox runtime.
FROM nixos/nix:2.24.9

# Enable flakes + the unified `nix` CLI.
# filter-syscalls=false keeps builds working under restrictive container runtimes.
RUN mkdir -p /etc/nix \
 && printf '%s\n' \
      'experimental-features = nix-command flakes' \
      'filter-syscalls = false' \
      'warn-dirty = false' \
      'max-jobs = auto' \
      >> /etc/nix/nix.conf

ENV NIX_CONFIG="experimental-features = nix-command flakes"
ENV LANG=C.UTF-8
ENV SHELL=/bin/bash

# The flake lives here; the actual project is bind-mounted at /workspace.
WORKDIR /opt/env
COPY docker/flake.nix ./
COPY docker/flake.lock ./

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
RUN cat > /opt/entrypoint.sh <<'EOF'
#!/bin/bash
set -euo pipefail

# Load PATH and all environment variables captured at image build time by
# `nix print-dev-env`. This replaces `nix develop` at runtime and avoids
# per-container Nix evaluation or store realisation.
source /opt/env/dev-shell-env.sh

# Re-run the mkShell shellHook so git identity/signing, the skills symlink,
# UV_PYTHON, and other runtime setup still happen on every entry.
[ -n "${shellHook:-}" ] && eval "$shellHook"

exec "$@"
EOF
RUN chmod +x /opt/entrypoint.sh
ENTRYPOINT ["/opt/entrypoint.sh"]
CMD ["bash", "-l"]

