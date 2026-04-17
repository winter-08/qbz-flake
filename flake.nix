{
  description = "qbz — native hi-fi Qobuz desktop player, packaged for Linux and macOS";

  inputs = {
    nixpkgs.url = "github:NixOS/nixpkgs/nixpkgs-unstable";
    flake-utils.url = "github:numtide/flake-utils";
  };

  outputs = { self, nixpkgs, flake-utils }:
    let
      # ────────────────────────────────────────────────────────────────
      # Pinned upstream release. Bumped automatically by
      # .github/workflows/update-check.yml.
      # ────────────────────────────────────────────────────────────────
      version = "1.2.7";
      srcHash = "sha256-/7gYjCfMJ1TmjogGQWkRDgDaUZ8o03hVNxZ21w4xniU=";
      npmHash = "sha256-xBad4Ms5dlE0jHZ5iKLS2dEujgIZahfNfcknJH9qoXM=";

      # Per-arch prebuilt DMGs used on darwin (Tauri/WebKit is impractical to
      # build from source on darwin under nix; upstream signs & publishes them).
      darwinAssets = {
        "aarch64-darwin" = {
          urlName = "QBZ_${version}_aarch64.dmg";
          hash = "sha256-f0MPMlh5XzYRp3j5PKb8NXgtdYk1dPvCoqNa+Ywl5Ig=";
        };
        "x86_64-darwin" = {
          urlName = "QBZ_${version}_x64.dmg";
          hash = "sha256-XlvO5EH2XzFOsWMSSQ8GrXLTLLGfV66wVCIAKuTqMsA=";
        };
      };

      supportedSystems = [
        "x86_64-linux"
        "aarch64-linux"
        "x86_64-darwin"
        "aarch64-darwin"
      ];
    in
    flake-utils.lib.eachSystem supportedSystems (system:
      let
        pkgs = import nixpkgs { inherit system; };
        inherit (pkgs) lib stdenv;

        commonMeta = {
          description = "Native, full-featured hi-fi Qobuz desktop player";
          homepage = "https://qbz.lol";
          downloadPage = "https://github.com/vicrodh/qbz/releases";
          license = lib.licenses.mit;
          mainProgram = "qbz";
        };

        # ────────────────────────────────────────────────────────────────
        # Linux: build from source via cargo-tauri.hook.
        # ────────────────────────────────────────────────────────────────
        qbzLinux = pkgs.rustPlatform.buildRustPackage (finalAttrs: {
          pname = "qbz";
          inherit version;

          src = pkgs.fetchFromGitHub {
            owner = "vicrodh";
            repo = "qbz";
            rev = "v${version}";
            hash = srcHash;
          };

          cargoRoot = "src-tauri";
          buildAndTestSubdir = "src-tauri";
          cargoLock.lockFile = "${finalAttrs.src}/src-tauri/Cargo.lock";

          npmDeps = pkgs.fetchNpmDeps {
            name = "qbz-${version}-npm-deps";
            inherit (finalAttrs) src;
            hash = npmHash;
          };

          # mupdf-sys runs bindgen, which needs LIBCLANG_PATH.
          env.LIBCLANG_PATH = "${lib.getLib pkgs.llvmPackages.libclang}/lib";

          nativeBuildInputs = with pkgs; [
            cargo-tauri.hook
            clang
            makeWrapper
            nodejs
            npmHooks.npmConfigHook
            pkg-config
          ];

          buildInputs = with pkgs; [
            alsa-lib
            libappindicator-gtk3
            libayatana-appindicator
            openssl
            webkitgtk_4_1
          ];

          checkFlags = [
            # Require a writable HOME and a D-Bus secret service at build time.
            "--skip=credentials::tests::test_credentials_roundtrip"
            "--skip=credentials::tests::test_encryption_roundtrip"
          ];

          postInstall = ''
            wrapProgram $out/bin/qbz \
              --prefix LD_LIBRARY_PATH : ${lib.makeLibraryPath (with pkgs; [
                libappindicator
                libappindicator-gtk3
                libayatana-appindicator
              ])}
          '';

          meta = commonMeta // {
            platforms = lib.platforms.linux;
          };
        });

        # ────────────────────────────────────────────────────────────────
        # Darwin: install the prebuilt, upstream-signed .app bundle.
        # ────────────────────────────────────────────────────────────────
        qbzDarwin =
          let
            asset = darwinAssets.${system};
          in
          stdenv.mkDerivation {
            pname = "qbz";
            inherit version;

            src = pkgs.fetchurl {
              url = "https://github.com/vicrodh/qbz/releases/download/v${version}/${asset.urlName}";
              inherit (asset) hash;
            };

            nativeBuildInputs = [ pkgs.undmg ];
            sourceRoot = ".";
            unpackPhase = "undmg $src";

            installPhase = ''
              runHook preInstall

              mkdir -p $out/Applications $out/bin
              cp -R "QBZ.app" "$out/Applications/QBZ.app"

              # CLI shim: launch the bundle's inner binary so `nix run` and
              # PATH-based invocations work.
              cat > $out/bin/qbz <<EOF
              #!${pkgs.runtimeShell}
              exec "$out/Applications/QBZ.app/Contents/MacOS/qbz" "\$@"
              EOF
              chmod +x $out/bin/qbz

              runHook postInstall
            '';

            dontFixup = true;

            meta = commonMeta // {
              platforms = lib.platforms.darwin;
              sourceProvenance = [ lib.sourceTypes.binaryNativeCode ];
            };
          };

        qbz = if stdenv.isDarwin then qbzDarwin else qbzLinux;
      in
      {
        packages = {
          default = qbz;
          qbz = qbz;
        };

        apps.default = {
          type = "app";
          program = "${qbz}/bin/qbz";
        };

        devShells.default = pkgs.mkShell {
          inputsFrom = lib.optional (!stdenv.isDarwin) qbzLinux;

          # `inputsFrom` propagates buildInputs/nativeBuildInputs but not
          # `env.*`, so LIBCLANG_PATH has to be re-exported for mupdf-sys.
          LIBCLANG_PATH = lib.optionalString (!stdenv.isDarwin)
            "${lib.getLib pkgs.llvmPackages.libclang}/lib";

          packages = with pkgs; [
            clippy
            rust-analyzer
            rustfmt
          ];

          # The installed binary is wrapped with LD_LIBRARY_PATH; inside
          # `nix develop` we run target/debug/qbz directly with no wrapper,
          # so we replicate the wrapper env here to make the tray loadable.
          shellHook = lib.optionalString (!stdenv.isDarwin) ''
            export LD_LIBRARY_PATH="${lib.makeLibraryPath (with pkgs; [
              libappindicator
              libappindicator-gtk3
              libayatana-appindicator
            ])}''${LD_LIBRARY_PATH:+:$LD_LIBRARY_PATH}"
          '';
        };

        formatter = pkgs.nixpkgs-fmt;
      });
}
