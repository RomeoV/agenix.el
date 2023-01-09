{
  description = "Decrypt and encrypt agenix secrets inside Emacs";

  inputs = {
    nixpkgs.url = "github:NixOS/nixpkgs/release-22.11";

    bash-strict-mode = {
      url = "github:sellout/bash-strict-mode";
      inputs.nixpkgs.follows = "nixpkgs";
    };

    flake-utils.url = "github:numtide/flake-utils";

    homeManager = {
      url = "github:nix-community/home-manager/release-22.11";
      inputs.nixpkgs.follows = "nixpkgs";
    };
  };

  outputs = inputs:
    {
      overlays = {
        default = final: prev: {
          emacsPackagesFor = emacs:
            (prev.emacsPackagesFor emacs).overrideScope'
            (inputs.self.overlays.emacs final prev);
        };

        emacs = final: prev: efinal: eprev: {
          agenix = inputs.self.packages.${final.system}.agenix-el;
        };
      };

      homeConfigurations.example = inputs.homeManager.lib.homeManagerConfiguration {
        pkgs = import inputs.nixpkgs {
          system = inputs.flake-utils.lib.system.aarch64-darwin;
          ## Users will refer to `inputs.agenix-el.overlays.default` instead.
          overlays = [inputs.self.overlays.default];
        };

        modules = [
          ./nix/home-manager-example.nix
          {
            # These attributes are simply required by home-manager.
            home = {
              homeDirectory = /tmp/agenix-el-example;
              stateVersion = "22.11";
              username = "agenix-el-example-user";
            };
          }
        ];
      };
    }
    // inputs.flake-utils.lib.eachDefaultSystem (system: let
      pkgs = import inputs.nixpkgs {
        inherit system;
        overlays = [(import ./nix/dependencies.nix)];
      };

      src = pkgs.lib.cleanSource ./.;

      emacsPackageDir = "share/emacs/site-lisp/elpa";

      emacsPath = package: "${package}/${emacsPackageDir}/${package.ename}-${package.version}";

      ## Read version in format: ;; Version: xx.yy
      readVersion = fp:
        builtins.elemAt
        (builtins.match ".*(;; Version: ([[:digit:]]+\.[[:digit:]]+)).*" (builtins.readFile fp))
        1;

      ## We need to tell Eldev where to find its Emacs package.
      ELDEV_LOCAL = emacsPath pkgs.emacsPackages.eldev;
    in {
      packages = {
        default = inputs.self.packages.${system}.agenix-el;

        agenix-el =
          inputs.bash-strict-mode.lib.checkedDrv pkgs
          (pkgs.emacsPackages.trivialBuild {
            inherit ELDEV_LOCAL src;

            pname = "agenix";
            version = readVersion ./agenix.el;

            nativeBuildInputs = [
              pkgs.emacs
              # Emacs-lisp build tool, https://doublep.github.io/eldev/
              pkgs.emacsPackages.eldev
            ];

            doCheck = true;

            checkPhase = ''
              runHook preCheck
              eldev test
              runHook postCheck
            '';

            doInstallCheck = true;

            instalCheckPhase = ''
              runHook preInstallCheck
              eldev --packaged test
              runHook postInstallCheck
            '';
          });
      };

      devShells.default =
        ## TODO: Use `inputs.bash-strict-mode.lib.checkedDrv` here after
        ##       NixOS/nixpkgs#204606 makes it into a release.
        inputs.bash-strict-mode.lib.drv pkgs
        (pkgs.mkShell {
          inputsFrom =
            builtins.attrValues inputs.self.checks.${system}
            ++ builtins.attrValues inputs.self.packages.${system};

          nativeBuildInputs = [
            # Nix language server,
            # https://github.com/oxalica/nil#readme
            pkgs.nil
            # Bash language server,
            # https://github.com/bash-lsp/bash-language-server#readme
            pkgs.nodePackages.bash-language-server
          ];
        });

      checks = {
        doctor =
          inputs.bash-strict-mode.lib.checkedDrv pkgs
          (pkgs.stdenv.mkDerivation {
            inherit ELDEV_LOCAL src;

            name = "eldev-doctor";

            nativeBuildInputs = [
              pkgs.emacs
              # Emacs-lisp build tool, https://doublep.github.io/eldev/
              pkgs.emacsPackages.eldev
            ];

            buildPhase = ''
              runHook preBuild
              eldev doctor
              runHook postBuild
            '';

            installPhase = ''
              runHook preInstall
              mkdir -p "$out"
              runHook postInstall
            '';
          });

        lint =
          inputs.bash-strict-mode.lib.checkedDrv pkgs
          (pkgs.stdenv.mkDerivation {
            inherit ELDEV_LOCAL src;

            name = "eldev-lint";

            nativeBuildInputs = [
              pkgs.emacs
              pkgs.emacsPackages.eldev
            ];

            postPatch = ''
              { echo
                echo "(mapcar"
                echo " 'eldev-use-local-dependency"
                echo " '(\"${emacsPath pkgs.emacsPackages.dash}\""
                echo "   \"${emacsPath pkgs.emacsPackages.elisp-lint}\""
                echo "   \"${emacsPath pkgs.emacsPackages.package-lint}\""
                echo "   \"${emacsPath pkgs.emacsPackages.relint}\""
                echo "   \"${emacsPath pkgs.emacsPackages.xr}\"))"
              } >> Eldev
            '';

            buildPhase = ''
              runHook preBuild
              ## TODO: Currently needed to make a temp file in
              ##      `eldev--create-internal-pseudoarchive-descriptor`.
              export HOME="$PWD/fake-home"
              mkdir -p "$HOME"
              ## NB: Need `--external` here so that we don’t try to download any
              ##     package archives (which would break the sandbox).
              ## TODO: Re-enable relint, currently it errors, I think because it
              ##       or Eldev is expecting a multi-file package.
              eldev --external lint elisp # re
              runHook postBuild
            '';

            installPhase = ''
              runHook preInstall
              mkdir -p "$out"
              runHook preInstall
            '';
          });

        nix-fmt = pkgs.stdenv.mkDerivation {
          inherit src;

          name = "nix fmt";

          nativeBuildInputs = [inputs.self.formatter.${system}];

          buildPhase = ''
            runHook preBuild
            alejandra --check .
            runHook postBuild
          '';

          installPhase = ''
            runHook preInstall
            mkdir -p "$out"
            runHook preInstall
          '';
        };
      };

      # Nix code formatter, https://github.com/kamadorueda/alejandra#readme
      formatter = pkgs.alejandra;
    });
}
