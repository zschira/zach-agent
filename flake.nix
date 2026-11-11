{
  description = "zach-agent container launcher";

  inputs = {
    nixpkgs.url = "github:NixOS/nixpkgs/nixos-25.05";
  };

  outputs = { self, nixpkgs }:
    let
      systems = [
        "x86_64-linux"
        "aarch64-linux"
        "x86_64-darwin"
        "aarch64-darwin"
      ];

      forAllSystems = f:
        nixpkgs.lib.genAttrs systems (system: f nixpkgs.legacyPackages.${system});

      # The CI workflow pushes ghcr.io/<repository_owner>/zach-agent; this
      # default must match that path. You can also override the whole
      # reference at runtime with ZACH_AGENT_IMAGE.
      imageRepo = "ghcr.io/zschira/zach-agent";
    in
    {
      packages = forAllSystems (pkgs:
        let
          # When this flake is evaluated from a locked source (e.g.
          # github:zschira/zach-agent), self.rev is the commit SHA. The image
          # built by CI is tagged with the same SHA, so launcher and image are
          # coupled without hardcoding versions. For a dirty local path, fall
          # back to latest.
          imageTag = if (self ? rev) && (self.rev != null) then self.rev else "latest";

          launcher = pkgs.writeShellScriptBin "zach-agent" ''
              set -euo pipefail
              export PATH="${pkgs.lib.makeBinPath [ pkgs.git pkgs.docker pkgs.coreutils ]}:$PATH"

              usage() {
                echo "usage: zach-agent <workspace-dir> [command...]" >&2
                exit 1
              }

              IMAGE="''${ZACH_AGENT_IMAGE:-${imageRepo}:${imageTag}}"

              workspace="''${1:-}"
              [[ -n "$workspace" ]] || usage
              workspace_abs=$(cd "$workspace" && pwd)
              shift

              AGENT_KEYS="''${AGENT_KEYS:-$HOME/.agent-keys}"

              env_name="''${ZACH_AGENT_UV_ENV_NAME:-$(basename "$workspace_abs")}"
              env_name="$(printf '%s' "$env_name" | tr '[:upper:]' '[:lower:]' | tr -c '[:alnum:]_-' '-')"
              UV_PROJECT_ENVIRONMENT="/opt/uv-envs/$env_name"

              GIT_AUTHOR_NAME=$(git -C "$workspace_abs" config --get user.name || true)
              GIT_AUTHOR_EMAIL=$(git -C "$workspace_abs" config --get user.email || true)

              if [[ -z "$GIT_AUTHOR_NAME" || -z "$GIT_AUTHOR_EMAIL" ]]; then
                echo "error: no git user.name/user.email configured for $workspace_abs" >&2
                exit 1
              fi

              key_mount=()
              if [[ -d "$AGENT_KEYS" ]]; then
                key_mount=(-v "$AGENT_KEYS:/run/agent-keys:ro")
              else
                echo "warning: $AGENT_KEYS not found; commits will be unsigned" >&2
              fi

              exec docker run --rm -it \
                -v "$workspace_abs:/workspace" \
                -v pi-agent-home:/root/.pi/agent \
                -v pi-agent-uv-envs:/opt/uv-envs \
                -v pi-agent-uv-cache:/opt/uv-cache \
                -e OPENROUTER_API_KEY \
                -e GIT_AUTHOR_NAME="$GIT_AUTHOR_NAME" \
                -e GIT_AUTHOR_EMAIL="$GIT_AUTHOR_EMAIL" \
                -e UV_PROJECT_ENVIRONMENT="$UV_PROJECT_ENVIRONMENT" \
                "''${key_mount[@]}" \
                "$IMAGE" "$@"
            '';
        in
        {
          zach-agent = launcher;
          default = launcher;
        });

      apps = forAllSystems (pkgs: {
        default = {
          type = "app";
          program = "${self.packages.${pkgs.system}.zach-agent}/bin/zach-agent";
        };
      });

      formatter = forAllSystems (pkgs: pkgs.nixpkgs-fmt);
    };
}
