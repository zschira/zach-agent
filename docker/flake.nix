{
  description = "zach-agent — sandboxed pi-coding-agent environment";

  inputs = {
    nixpkgs.url = "github:NixOS/nixpkgs/nixos-25.05";

    # Skill repos. `flake = false` means "just fetch the source tree" — the
    # repos don't need to contain a flake.nix. Each revision is pinned in
    # flake.lock; bump one with:
    #   nix flake update agent-skills
    agent-skills = {
      url = "github:catalyst-cooperative/agent-skills";
      flake = false;
    };

    anthropic-skills = {
      url = "github:anthropics/skills";
      flake = false;
    };

    # `release-stable` tracks each weekly Dagster release and is what every
    # upstream install path delivers; `master` carries unreleased content.
    # Skills sit at plugins/<plugin>/skills/<skill>/SKILL.md — found by Pi's
    # recursive discovery.
    dagster-skills = {
      url = "github:dagster-io/skills/release-stable";
      flake = false;
    };
  };

  outputs = inputs@{ self, nixpkgs, ... }:
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
      piPackage = "@earendil-works/pi-coding-agent";
      piVersion = "1.5.2";

      # Map of <directory name under ~/.agents/skills> -> <fetched source>.
      # Pi discovers directories containing SKILL.md recursively, so a repo
      # bundling many skills can be dropped in whole as a single entry.
      skillSources = {
        catalyst-cooperative = inputs.agent-skills;
        anthropic = inputs.anthropic-skills;
        dagster = inputs.dagster-skills;
      };
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

        # Every pinned skill repo collected into one read-only store path:
        #   /nix/store/...-pi-skills/<name>/...
        # Pi walks this recursively looking for SKILL.md.
        pi-skills = pkgs.runCommand "pi-skills" { } (''
          mkdir -p $out
        '' + pkgs.lib.concatStringsSep "\n" (pkgs.lib.mapAttrsToList
          (name: src: ''
            cp -rL ${src} $out/${name}
            chmod -R u+w $out/${name}
            if ! find $out/${name} -name SKILL.md | grep -q .; then
              echo "error: no SKILL.md found under skill input '${name}'" >&2
              exit 1
            fi
          '')
          skillSources));

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
            openssh # ssh-keygen; git shells out to it for SSH commit signing
            ripgrep
            duckdb

            # quality-of-life
            fd
            jq
            curl
            tree

            # Python for skills. Skills declare deps as prose in their
            # `compatibility` frontmatter (there is no machine-readable
            # manifest), so this list is maintained by hand.
            #   catalyst-cooperative/pudl: polars, pandas+s3fs
            #   anthropic/pdf:             pypdf, pdfplumber, reportlab, pandas
            (python312.withPackages (ps: with ps; [
              polars
              pandas
              s3fs
              pyarrow
              requests
              pypdf
              pdfplumber
              reportlab
            ]))

            # CLI tools the pdf skill shells out to
            poppler-utils # pdftotext, pdfimages
            qpdf

            # Package manager for mounted projects. See AGENTS.md for the
            # dynamic-linker and host-.venv caveats. `pixi` is deliberately
            # absent: conda-forge packages ship their own interpreter, which
            # needs an FHS dynamic linker this image does not provide.
            uv

            # pi-coding-agent runtime
            nodejs_22
          ];

          env = {
            ZACH_AGENT_HOME = "/workspace/.agent";
            # Keep globally-installed npm bins inside the sandbox, not in $HOME.
            NPM_CONFIG_PREFIX = "/opt/npm";
            NPM_CONFIG_UPDATE_NOTIFIER = "false";

            # Read-only store path holding every pinned skill repo.
            PI_SKILLS_STORE = "${self.packages.${pkgs.system}.pi-skills}";

            # Host ~/.agent-keys, bind-mounted read-only by `make develop`.
            AGENT_KEYS_DIR = "/run/agent-keys";

            # uv's managed CPython builds are prebuilt for generic Linux and
            # cannot start here (no /lib64/ld-linux-x86-64.so.2). Force uv onto
            # the Nix interpreter instead.
            UV_PYTHON_DOWNLOADS = "never";

            # Keep the container's venv OUT of the bind-mounted project. A venv
            # hardcodes absolute paths (interpreter symlink, pyvenv.cfg `home`,
            # script shebangs), so a host-created /workspace/.venv is not usable
            # here — and `uv sync` would delete and recreate it, breaking manual
            # development on the host. The launcher sets a per-project
            # UV_PROJECT_ENVIRONMENT under /opt/uv-envs; this default only applies
            # when the image is run outside the launcher.
            UV_PROJECT_ENVIRONMENT = "/opt/uv-envs/default";

            # Package downloads are cached here; put it on a volume too,
            # otherwise every run re-fetches every wheel.
            UV_CACHE_DIR = "/opt/uv-cache";
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

            # Set here rather than in `env` because it needs the interpreter
            # that PATH actually resolves to.
            export UV_PYTHON="$(command -v python3)"

            # --- git identity ------------------------------------------------
            # GIT_AUTHOR_* are injected by `make develop`, read from the host's
            # git config as resolved inside the workspace repo. Environment
            # variables outrank *every* config file, so a mounted repo's local
            # user.name/user.email cannot override them. You stay the author;
            # the agent is recorded as committer, per aider's convention.
            if [ -n "''${GIT_AUTHOR_NAME:-}" ]; then
              export GIT_COMMITTER_NAME="''${GIT_AUTHOR_NAME} (aider)"
              export GIT_COMMITTER_EMAIL="''${GIT_AUTHOR_EMAIL:-}"
            else
              echo "warning: GIT_AUTHOR_NAME unset; commits fall back to git's default identity" >&2
            fi

            # --- commit signing ----------------------------------------------
            # The key is created on the host in ~/.agent-keys and bind-mounted
            # read-only at $AGENT_KEYS_DIR. Nothing is generated here, and the
            # directory is absent during `docker build`, which is what skips
            # this block.
            if [ -d "$AGENT_KEYS_DIR" ]; then
              if [ -z "''${AGENT_SIGNING_KEY:-}" ]; then
                set -- "$AGENT_KEYS_DIR"/*.pub
                if [ "$#" -eq 1 ] && [ -f "$1" ]; then
                  AGENT_SIGNING_KEY="$1"
                else
                  echo "warning: expected exactly one *.pub in $AGENT_KEYS_DIR (found $#); set AGENT_SIGNING_KEY" >&2
                fi
              fi
            else
              echo "warning: $AGENT_KEYS_DIR not mounted; commits will be unsigned" >&2
            fi

            if [ -n "''${AGENT_SIGNING_KEY:-}" ] && [ -f "$AGENT_SIGNING_KEY" ]; then
              # Rebuilt on each entry because the key mount is read-only.
              # namespaces="git" stops the signature being replayed in another
              # SSH context.
              allowed_signers="''${HOME:-/root}/.ssh/allowed_signers"
              mkdir -p "$(dirname "$allowed_signers")"
              chmod 700 "$(dirname "$allowed_signers")"
              printf '%s namespaces="git" %s\n' \
                "''${GIT_COMMITTER_EMAIL:-zach-agent@localhost}" \
                "$(cat "$AGENT_SIGNING_KEY")" > "$allowed_signers"

              # "command" scope: overrides every config file, including a
              # mounted repo's .git/config. Inherited by git subprocesses.
              export GIT_CONFIG_COUNT=5
              export GIT_CONFIG_KEY_0=gpg.format
              export GIT_CONFIG_VALUE_0=ssh
              export GIT_CONFIG_KEY_1=user.signingkey
              export GIT_CONFIG_VALUE_1="$AGENT_SIGNING_KEY"
              export GIT_CONFIG_KEY_2=commit.gpgsign
              export GIT_CONFIG_VALUE_2=true
              export GIT_CONFIG_KEY_3=tag.gpgsign
              export GIT_CONFIG_VALUE_3=true
              export GIT_CONFIG_KEY_4=gpg.ssh.allowedSignersFile
              export GIT_CONFIG_VALUE_4="$allowed_signers"

              echo "  git     ''${GIT_AUTHOR_NAME:-<unset>} / committer ''${GIT_COMMITTER_NAME:-<unset>} (signed)"
            else
              echo "  git     ''${GIT_AUTHOR_NAME:-<unset>} / committer ''${GIT_COMMITTER_NAME:-<unset>} (UNSIGNED)"
            fi

            # safe.directory stays in --global rather than command scope:
            # command-scope support for it is incomplete (notably `git clone`).
            # /workspace is host-owned, so git refuses to touch it otherwise.
            git config --global --replace-all safe.directory /workspace

            # Pi discovers skills recursively under ~/.agents/skills, so expose
            # the store path there as a symlink. Re-pointed on every entry so a
            # rebuilt pi-skills takes effect.
            skills_dir="''${HOME:-/root}/.agents/skills"
            mkdir -p "$skills_dir"
            ln -sfn "$PI_SKILLS_STORE" "$skills_dir/nix"

            echo "  skills  $(find -L "$skills_dir" -name SKILL.md | wc -l) found in $skills_dir"

            # The launcher may override this with a per-project path.
            mkdir -p "$UV_PROJECT_ENVIRONMENT"
          '';
        };
      });

      formatter = forAllSystems (pkgs: pkgs.nixpkgs-fmt);
    };
}
