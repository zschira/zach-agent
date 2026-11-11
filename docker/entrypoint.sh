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
