{
  description = "zach-agent — sandboxed pi-coding-agent environment";

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

      # pi-coding-agent is distributed on npm. Pin the version here; bump + refresh
      # the hash when you want a newer agent.
      piPackage = "@mariozechner/pi-coding-agent";
      piVersion = "0.73.1";
    in
    {
      packages = forAllSystems (pkgs: {
        # Vendored npm install of the agent, so the container does not need
        # network access at runtime.
        #
        # First build will fail with the expected `npmDepsHash`; copy it in.
        pi-coding-agent = pkgs.buildNpmPackage {
          pname = "pi-coding-agent";
          version = piVersion;

          src = pkgs.fetchurl {
            url = "https://registry.npmjs.org/${piPackage}/-/pi-coding-agent-${piVersion}.tgz";
            hash = pkgs.lib.fakeHash; # TODO: replace with real sha256-...
          };

          npmDepsHash = pkgs.lib.fakeHash; # TODO: replace with real sha256-...
          dontNpmBuild = true;

          meta = {
            description = "pi coding agent CLI";
            mainProgram = "pi";
          };
        };

        default = self.packages.${pkgs.system}.pi-coding-agent;
      });

      devShells = forAllSystems (pkgs: {
        default = pkgs.mkShell {
          name = "zach-agent";

          packages = with pkgs; [
            # shell basics
            bashInteractive
            coreutils
            findutils
            gnused
            gnugrep
            less

            # standard tooling
            git
            ripgrep
            duckdb

            # quality-of-life
            fd
            jq
            curl
            tree

            # pi-coding-agent runtime
            nodejs_22
          ];

          env = {
            ZACH_AGENT_HOME = "/workspace/.agent";
            # Keep globally-installed npm bins inside the sandbox, not in $HOME.
            NPM_CONFIG_PREFIX = "/opt/npm";
            NPM_CONFIG_UPDATE_NOTIFIER = "false";
          };

          shellHook = ''
            export PATH="$NPM_CONFIG_PREFIX/bin:$PATH"
            mkdir -p "$ZACH_AGENT_HOME" "$NPM_CONFIG_PREFIX"

            # Bootstrap the agent on first use (swap for the vendored package
            # above once the hashes are pinned).
            if ! command -v pi >/dev/null 2>&1; then
              echo "installing ${piPackage}@${piVersion}..."
              npm install -g "${piPackage}@${piVersion}"
            fi

            echo "zach-agent sandbox"
            echo "  node    $(node --version)"
            echo "  pi      $(pi --version 2>/dev/null || echo 'not installed')"
            echo "  git     $(git --version | cut -d' ' -f3)"
            echo "  rg      $(rg --version | head -n1 | cut -d' ' -f2)"
            echo "  duckdb  $(duckdb --version | cut -d' ' -f1)"
          '';
        };
      });

      formatter = forAllSystems (pkgs: pkgs.nixpkgs-fmt);
    };
}
