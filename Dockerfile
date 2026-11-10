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
COPY flake.nix ./
COPY flake.loc[k] ./

# Realise the dev shell closure and pin it with a profile so it survives `nix gc`
# and so container start-up does no network/eval work.
RUN nix develop --profile /nix/var/nix/profiles/devshell --command true

WORKDIR /workspace

# Declared, not populated: the real value is injected at runtime so it never
# ends up in an image layer or in /nix/store.
ENV OPENROUTER_API_KEY=""

# Everything runs inside the pinned dev shell:
#   docker run --rm -it -v "$PWD:/workspace" \
#     -e OPENROUTER_API_KEY zach-agent
#   docker run --rm    -v "$PWD:/workspace" \
#     --env-file .env zach-agent pi --version
ENTRYPOINT ["nix", "develop", "/nix/var/nix/profiles/devshell", "--command"]
CMD ["bash", "-l"]

