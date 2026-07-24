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
      version = "2.0.2";

      # Per-system prebuilt release assets. Upstream builds & signs the
      # darwin .dmgs and ships matching Linux binary tarballs; using them
      # avoids a heavy Rust/webkit toolchain in the closure and matches
      # the upstream binary exactly.
      releaseAssets = {
        "x86_64-linux" = {
          urlName = "qbz_${version}_amd64.tar.gz";
          hash = "sha256-bg+elpapUtVmpWMoeZovD5UeC247H0e6PAFvkmIr6ks=";
        };
        "aarch64-linux" = {
          urlName = "qbz_${version}_aarch64.tar.gz";
          hash = "sha256-E+ecxJNb5JC+I2TU6RzcLobe8PZA8pee9Rulrj4vVTE=";
        };
        "aarch64-darwin" = {
          urlName = "QBZ_${version}_aarch64.dmg";
          hash = "sha256-eozvpWQi+YVtu4NbrAzrOaqJGnWOQTOhaJR06jEPhgU=";
        };
        "x86_64-darwin" = {
          urlName = "QBZ_${version}_x64.dmg";
          hash = "sha256-JapUqWx+gsspHJ+7Lw5sWXpeBZSS4QvtQ5o/ucSLR0o=";
        };
      };

      supportedSystems = builtins.attrNames releaseAssets;
    in
    flake-utils.lib.eachSystem supportedSystems (system:
      let
        pkgs = import nixpkgs { inherit system; };
        inherit (pkgs) lib stdenv;

        asset = releaseAssets.${system};

        commonMeta = {
          description = "Native, full-featured hi-fi Qobuz desktop player";
          homepage = "https://qbz.lol";
          downloadPage = "https://github.com/vicrodh/qbz/releases";
          license = lib.licenses.mit;
          mainProgram = "qbz";
          sourceProvenance = [ lib.sourceTypes.binaryNativeCode ];
        };

        # qbz dlopens its windowing and tray libraries at runtime rather
        # than linking them, so autoPatchelfHook can't pick these up — they
        # need to be on LD_LIBRARY_PATH instead.
        linuxRuntimeLibs = with pkgs; [
          libappindicator
          libappindicator-gtk3
          libayatana-appindicator
          libxkbcommon
          wayland
        ];

        linuxRuntimePrograms = with pkgs; [
          alsa-utils
          pipewire
          pulseaudio
        ];

        # ────────────────────────────────────────────────────────────────
        # Linux: install the prebuilt upstream tarball.
        # ────────────────────────────────────────────────────────────────
        qbzLinux = stdenv.mkDerivation {
          pname = "qbz";
          inherit version;

          src = pkgs.fetchurl {
            url = "https://github.com/vicrodh/qbz/releases/download/v${version}/${asset.urlName}";
            inherit (asset) hash;
          };

          nativeBuildInputs = with pkgs; [
            autoPatchelfHook
            makeWrapper
          ];

          buildInputs = with pkgs; [
            alsa-lib
            cairo
            dbus
            fontconfig
            freetype
            gdk-pixbuf
            glib
            gtk3
            harfbuzz
            libsoup_3
            openssl
            pango
            webkitgtk_4_1
            zlib
          ] ++ linuxRuntimeLibs;

          installPhase = ''
            runHook preInstall

            install -Dm755 qbz "$out/bin/qbz"
            mkdir -p "$out/share"
            cp -r icons "$out/share/icons"
            install -Dm644 qbz.desktop "$out/share/applications/com.blitzfc.qbz.desktop"

            runHook postInstall
          '';

          postFixup = ''
            wrapProgram $out/bin/qbz \
              --prefix LD_LIBRARY_PATH : ${lib.makeLibraryPath linuxRuntimeLibs} \
              --prefix PATH : ${lib.makeBinPath linuxRuntimePrograms}
          '';

          meta = commonMeta // {
            platforms = lib.platforms.linux;
          };
        };

        # ────────────────────────────────────────────────────────────────
        # Darwin: install the prebuilt, upstream-signed .app bundle.
        # ────────────────────────────────────────────────────────────────
        qbzDarwin = stdenv.mkDerivation {
          pname = "qbz";
          inherit version;

          src = pkgs.fetchurl {
            url = "https://github.com/vicrodh/qbz/releases/download/v${version}/${asset.urlName}";
            inherit (asset) hash;
          };

          nativeBuildInputs = [ pkgs._7zz ];
          sourceRoot = ".";
          unpackPhase = ''
            runHook preUnpack

            7zz x "$src" -o"$TMPDIR/extract" -y

            runHook postUnpack
          '';

          installPhase = ''
            runHook preInstall

            mkdir -p $out/Applications $out/bin
            cp -R "$TMPDIR/extract/QBZ.app" "$out/Applications/QBZ.app"

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
          packages = [ pkgs.nixpkgs-fmt ];
        };

        formatter = pkgs.nixpkgs-fmt;
      });
}
