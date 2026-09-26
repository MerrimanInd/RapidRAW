{
  description = "RapidRAW – GPU-accelerated, non-destructive RAW photo editor (Tauri + React + wgpu)";

  inputs = {
    nixpkgs.url = "github:NixOS/nixpkgs/nixos-unstable";

    # src-tauri/rust-toolchain.toml pins Rust 1.98 (edition 2024, rust-version = "1.98"),
    # which may be newer than nixpkgs' rustc. rust-overlay lets us honour the pin exactly.
    rust-overlay = {
      url = "github:oxalica/rust-overlay";
      inputs.nixpkgs.follows = "nixpkgs";
    };
  };

  outputs =
    {
      self,
      nixpkgs,
      rust-overlay,
    }:
    let
      inherit (nixpkgs) lib;

      systems = [
        "x86_64-linux"
        "aarch64-linux"
        "x86_64-darwin"
        "aarch64-darwin"
      ];

      forAllSystems =
        f:
        lib.genAttrs systems (
          system:
          f (
            import nixpkgs {
              inherit system;
              overlays = [ rust-overlay.overlays.default ];
            }
          )
        );

      # ------------------------------------------------------------------------
      # ONNX Runtime
      #
      # src-tauri/build.rs downloads a prebuilt onnxruntime from Hugging Face at
      # build time, which fails inside the Nix sandbox. It skips the download if
      # src-tauri/resources/<lib> already exists with the right SHA-256, so we
      # prefetch it here with the same hashes build.rs uses and drop it in place.
      #
      # At runtime lib.rs sets ORT_DYLIB_PATH to the bundled resource copy
      # (ort is built with `load-dynamic`), so it just needs to ship as a resource.
      # ------------------------------------------------------------------------
      ortBaseUrl = "https://huggingface.co/CyberTimon/RapidRAW-Models/resolve/main/onnxruntimes-v1.22.0";

      ortFor = {
        x86_64-linux = {
          file = "libonnxruntime-linux-x86_64.so";
          lib = "libonnxruntime.so";
          sha256 = "3da6146e14e7b8aaec625dde11d6114c7457c87a5f93d744897da8781e35c673";
        };
        aarch64-linux = {
          file = "libonnxruntime-linux-aarch64.so";
          lib = "libonnxruntime.so";
          sha256 = "0afd69a0ae38c5099fd0e8604dda398ac43dee67cd9c6394b5142b19e82528de";
        };
        x86_64-darwin = {
          file = "libonnxruntime-macos-x86_64.dylib";
          lib = "libonnxruntime.dylib";
          sha256 = "283e595e61cf65df7a6b1d59a1616cbd35c8b6399dd90d799d99b71a3ff83160";
        };
        aarch64-darwin = {
          file = "libonnxruntime-macos-aarch64.dylib";
          lib = "libonnxruntime.dylib";
          sha256 = "2b885992d3d6fa4130d39ec84a80d7504ff52750027c547bb22c86165f19406a";
        };
      };

      # Rust toolchain straight from the repo's pin.
      toolchainFor = pkgs: pkgs.rust-bin.fromRustupToolchainFile ./src-tauri/rust-toolchain.toml;

      # Native libraries needed to build/run the Tauri shell on Linux.
      linuxBuildInputs =
        pkgs: with pkgs; [
          webkitgtk_4_1
          gtk3
          glib
          glib-networking
          libsoup_3
          cairo
          pango
          gdk-pixbuf
          atk
          openssl
          dbus
          librsvg
        ];

      # Loaded via dlopen by wgpu / winit at runtime – not linked, so they
      # must be put on LD_LIBRARY_PATH explicitly.
      linuxRuntimeLibs =
        pkgs: with pkgs; [
          vulkan-loader
          libGL
          wayland
          libxkbcommon
          xorg.libX11
          xorg.libXcursor
          xorg.libXi
          xorg.libXrandr
        ];

      mkRapidRAW =
        pkgs:
        {
          tethering ? false,
        }:
        let
          toolchain = toolchainFor pkgs;
          rustPlatform = pkgs.makeRustPlatform {
            cargo = toolchain;
            rustc = toolchain;
          };
          ort = ortFor.${pkgs.stdenv.hostPlatform.system};
          ortLib = pkgs.fetchurl {
            url = "${ortBaseUrl}/${ort.file}?download=true";
            name = ort.file;
            inherit (ort) sha256;
          };
        in
        rustPlatform.buildRustPackage (finalAttrs: {
          pname = "rapidraw" + lib.optionalString tethering "-tethering";
          version = "1.6.4"; # from src-tauri/tauri.conf.json

          # Assumes this flake lives at the repo root. Only git-tracked files are
          # visible to the flake, so the gitignored resources/libonnxruntime.* is
          # never picked up from a dev checkout.
          src = ./.;

          # Cargo workspace lives in src-tauri/, npm project at the root.
          cargoRoot = "src-tauri";
          buildAndTestSubdir = finalAttrs.cargoRoot;

          # TODO: replace after the first build prints the real hash.
          # (Git deps rawler + gphoto2/gphoto2-sys are handled by fetchCargoVendor.)
          cargoHash = lib.fakeHash;

          npmDeps = pkgs.fetchNpmDeps {
            name = "${finalAttrs.pname}-${finalAttrs.version}-npm-deps";
            inherit (finalAttrs) src;
            hash = lib.fakeHash; # TODO
          };

          postPatch = ''
            # Pre-seed onnxruntime so build.rs skips its network download.
            mkdir -p src-tauri/resources
            cp ${ortLib} src-tauri/resources/${ort.lib}
            chmod u+w src-tauri/resources/${ort.lib}
          '';

          nativeBuildInputs =
            (with pkgs; [
              cargo-tauri.hook # runs `cargo tauri build` + installs the bundle
              nodejs_22
              npmHooks.npmConfigHook # `npm ci` from npmDeps (offline)
              pkg-config
            ])
            ++ lib.optionals pkgs.stdenv.hostPlatform.isLinux [ pkgs.wrapGAppsHook3 ];

          buildInputs =
            lib.optionals pkgs.stdenv.hostPlatform.isLinux (linuxBuildInputs pkgs)
            # oniguruma for `tokenizers` (onig feature) – use the system lib
            # instead of the vendored C build.
            ++ [ pkgs.oniguruma ]
            ++ lib.optionals tethering [ pkgs.libgphoto2 ];

          env = {
            RUSTONIG_SYSTEM_LIBONIG = true;
          };

          # `cargo tauri build -- --features tethering`
          tauriBuildFlags = lib.optionals tethering [
            "--features"
            "tethering"
          ];
          buildFeatures = lib.optionals tethering [ "tethering" ];

          # Linux: only produce the .deb (the hook unpacks it into $out).
          # AppImage/rpm bundling needs network + FHS tricks.
          tauriBundleType = lib.optionalString pkgs.stdenv.hostPlatform.isLinux "deb";

          # The upstream test suite may need a GPU / sample files.
          doCheck = false;

          preFixup = lib.optionalString pkgs.stdenv.hostPlatform.isLinux ''
            gappsWrapperArgs+=(
              --prefix LD_LIBRARY_PATH : ${lib.makeLibraryPath (linuxRuntimeLibs pkgs)}
              # Uncomment if you hit the WebKit + NVIDIA/Wayland crash (upstream #306):
              # --set-default WEBKIT_DISABLE_DMABUF_RENDERER 1
            )
          '';

          meta = {
            description = "Non-destructive, GPU-accelerated RAW image editor";
            homepage = "https://github.com/CyberTimon/RapidRAW";
            license = lib.licenses.agpl3Only;
            mainProgram = "RapidRAW";
            platforms = systems;
          };
        });
    in
    {
      packages = forAllSystems (pkgs: {
        default = mkRapidRAW pkgs { };
        rapidraw = mkRapidRAW pkgs { };
        rapidraw-tethering = mkRapidRAW pkgs { tethering = true; };
      });

      apps = forAllSystems (pkgs: {
        default = {
          type = "app";
          program = lib.getExe self.packages.${pkgs.stdenv.hostPlatform.system}.default;
        };
      });

      # `nix develop` → `npm install && npm start` (or `npm run start:tethering`)
      devShells = forAllSystems (
        pkgs:
        let
          toolchain = (toolchainFor pkgs).override {
            extensions = [
              "rust-src"
              "rust-analyzer"
              "clippy"
              "rustfmt"
            ];
          };
        in
        {
          default = pkgs.mkShell {
            packages = [
              toolchain
              pkgs.nodejs_22
              pkgs.cargo-tauri
              pkgs.pkg-config
              pkgs.oniguruma
              pkgs.libgphoto2 # for the `tethering` feature
            ]
            ++ lib.optionals pkgs.stdenv.hostPlatform.isLinux (linuxBuildInputs pkgs);

            RUSTONIG_SYSTEM_LIBONIG = 1;

            shellHook = lib.optionalString pkgs.stdenv.hostPlatform.isLinux ''
              export LD_LIBRARY_PATH=${lib.makeLibraryPath (linuxRuntimeLibs pkgs)}''${LD_LIBRARY_PATH:+:$LD_LIBRARY_PATH}
              export GIO_MODULE_DIR=${pkgs.glib-networking}/lib/gio/modules/
              export XDG_DATA_DIRS=${pkgs.gsettings-desktop-schemas}/share/gsettings-schemas/${pkgs.gsettings-desktop-schemas.name}:${pkgs.gtk3}/share/gsettings-schemas/${pkgs.gtk3.name}''${XDG_DATA_DIRS:+:$XDG_DATA_DIRS}
            '';
          };
        }
      );

      formatter = forAllSystems (pkgs: pkgs.nixfmt-rfc-style);
    };
}
