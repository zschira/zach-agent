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
ENTRYPOINT ["/entrypoint.sh"]
CMD ["bash", "-l"]

