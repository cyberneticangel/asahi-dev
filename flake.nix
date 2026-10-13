{
  description = "Personal dev environment for Asahi Linux bring-up work (m1n1 + kernel)";

  inputs = {
    nixpkgs.url = "github:NixOS/nixpkgs/nixos-unstable";
    rust-overlay = {
      url = "github:oxalica/rust-overlay";
      inputs.nixpkgs.follows = "nixpkgs";
    };
  };

  outputs =
    { nixpkgs, rust-overlay, ... }:
    let
      systems = [
        "aarch64-darwin" # your Mac (m1n1, proxyclient, hypervisor host)
        "aarch64-linux" # Linux VM on the Mac (kernel builds)
        "x86_64-linux" # any other Linux box acting as proxy host
      ];
      forAllSystems =
        f:
        nixpkgs.lib.genAttrs systems (
          system:
          f (
            import nixpkgs {
              inherit system;
              overlays = [ rust-overlay.overlays.default ];
            }
          )
        );
    in
    {
      devShells = forAllSystems (
        pkgs:
        let
          inherit (pkgs) lib;
          llvm = pkgs.llvmPackages;

          # Bare-metal cross toolchain for m1n1 (and anything else freestanding).
          # Unwrapped clang avoids the Nix cc-wrapper injecting host libc / macOS
          # flags; -resource-dir points it at its own builtin headers so the
          # Makefile's `$(CC) -print-file-name=include` resolves correctly.
          clangBare = pkgs.writeShellScriptBin "clang" ''
            exec ${llvm.clang-unwrapped}/bin/clang -resource-dir=${llvm.clang}/resource-root "$@"
          '';
          bareToolchain = pkgs.symlinkJoin {
            name = "asahi-bare-toolchain";
            paths = [
              clangBare # must come first so it shadows the unwrapped clang
              llvm.clang-unwrapped # clang-format etc.
              llvm.lld # ld.lld
              llvm.llvm # llvm-objcopy, llvm-objdump, llvm-nm, ...
            ];
          };

          # m1n1 builds its Rust part for a bare-metal target.
          rustM1n1 = pkgs.rust-bin.stable.latest.default.override {
            extensions = [
              "rust-src"
              "rust-analyzer"
            ];
            targets = [ "aarch64-unknown-none-softfloat" ];
          };

          # Rust-for-Linux needs rust-src plus the usual linting tools.
          rustKernel = pkgs.rust-bin.stable.latest.default.override {
            extensions = [
              "rust-src"
              "rustfmt"
              "clippy"
              "rust-analyzer"
            ];
          };

          # m1n1 proxyclient deps (requirements.txt) + pytest (tests/python).
          pythonEnv = pkgs.python3.withPackages (
            ps: with ps; [
              construct
              pyserial
              pytest
            ]
          );

          common = with pkgs; [
            git
            gnumake
            dtc # dtc / fdtdump for device trees
            pythonEnv
            xz
            gzip
            picocom # serial console (proxyclient/tools/picocom-sec.sh)
          ];
        in
        {
          # m1n1 + proxyclient + hypervisor host tooling. Works on macOS and Linux.
          default = pkgs.mkShellNoCC {
            name = "m1n1";
            packages = common ++ [
              bareToolchain
              rustM1n1
              pkgs.imagemagick # only needed for `make LOGO=...`
            ];

            # All of these are `?=` in m1n1's Makefile, so the environment wins.
            USE_CLANG = "1";
            TOOLCHAIN = "${bareToolchain}/bin/";
            LLDDIR = "${bareToolchain}/bin/";
            ARCH = "aarch64-linux-gnu-"; # used as clang --target=, even on aarch64 hosts

            shellHook = ''
              echo "m1n1 shell: clang $(${clangBare}/bin/clang --version | head -1 | awk '{print $NF}'), $(rustc --version)"
              echo "  build:  make -C path/to/m1n1 -j  (CHAINLOADING=1 / RELEASE=1 optional)"
              echo "  proxy:  export M1N1DEVICE=/dev/cu.usbmodem<...>  (macOS) or /dev/ttyACM0 (Linux)"
            '';
          };
        }
        // lib.optionalAttrs pkgs.stdenv.hostPlatform.isLinux {
          # Asahi kernel (AsahiLinux/linux, branch `asahi`). Linux only:
          # macOS' case-insensitive filesystem breaks kernel trees.
          # Intended for a native aarch64-linux VM; build with `make LLVM=1`.
          kernel = (pkgs.mkShell.override { stdenv = llvm.stdenv; }) {
            name = "asahi-kernel";
            packages =
              common
              ++ (with pkgs; [
                llvm.lld
                llvm.llvm
                rustKernel
                rust-bindgen
                bc
                bison
                flex
                openssl
                elfutils
                ncurses
                pkg-config
                perl
                cpio
                kmod
                zstd
                lz4
                pahole
              ]);

            # The Nix compiler wrapper's hardening flags break kernel builds.
            hardeningDisable = [ "all" ];
            LLVM = "1";
            ARCH = "arm64";

            shellHook = ''
              echo "kernel shell: $(clang --version | head -1), $(rustc --version)"
              echo "  check Rust support:  make rustavailable"
              echo "  configure / build:   make defconfig  (or your own config) && make -j$(nproc)"
            '';
          };
        }
      );

      formatter = forAllSystems (pkgs: pkgs.nixfmt);
    };
}
