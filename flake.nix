{
  # Build with:
  #
  #   nix build 'git+https://github.com/eisbaw/nfs-ganesha?submodules=1&ref=ontap-work#nfs-ganesha'
  #
  # or, from a checkout:  nix build '.?submodules=1#nfs-ganesha'
  #
  # The git+https scheme and submodules=1 are both required. A github: ref
  # silently ignores submodules=1 because it fetches a tarball, and tarballs
  # cannot carry submodules -- src/libntirpc and src/libkmip then arrive empty
  # and cmake fails at add_subdirectory(). Submodules are needed recursively:
  # ntirpc's monitoring code includes prometheus-cpp-lite from its own
  # submodule.
  description = "nfs-ganesha PROXY_V3 with the ONTAP READDIR and xdrmem read fixes";

  inputs.nixpkgs.url = "github:NixOS/nixpkgs/nixos-unstable";

  outputs =
    { self, nixpkgs }:
    let
      system = "x86_64-linux";
      pkgs = nixpkgs.legacyPackages.${system};

      nativeDeps = with pkgs; [
        cmake
        pkg-config
        bison
        flex
        dbus
      ];

      # ntirpc is deliberately NOT taken from nixpkgs: ganesha 15.x needs the
      # matching ntirpc from its own submodule, so we build the bundled one.
      runtimeDeps = with pkgs; [
        acl
        krb5
        jemalloc
        libcap
        liburcu
        nfs-utils
        openssl
        # Required even though we do not want metrics: ganesha's stats code is
        # not cleanly #ifdef'd, so USE_MONITORING=OFF fails to compile.
        prometheus-cpp-lite
        dbus
      ];

      # Only PROXY_V3 is wanted here. Everything else off keeps the build small
      # and removes dependencies we would otherwise have to satisfy.
      cmakeFlags = [
        "-DUSE_SYSTEM_NTIRPC=OFF"
        "-DSYSSTATEDIR=/var"
        "-DCMAKE_BUILD_TYPE=RelWithDebInfo"
        "-DDEBUG_SYMS=ON"
        "-DCMAKE_BUILD_WITH_INSTALL_RPATH=ON"
        "-DUSE_FSAL_PROXY_V3=ON"
        "-DUSE_FSAL_PROXY_V4=OFF"
        "-DUSE_FSAL_VFS=OFF"
        "-DUSE_FSAL_XFS=OFF"
        "-DUSE_FSAL_LUSTRE=OFF"
        "-DUSE_FSAL_LIZARDFS=OFF"
        "-DUSE_FSAL_KVSFS=OFF"
        "-DUSE_FSAL_CEPH=OFF"
        "-DUSE_FSAL_GPFS=OFF"
        "-DUSE_FSAL_GLUSTER=OFF"
        "-DUSE_FSAL_NULL=OFF"
        "-DUSE_FSAL_RGW=OFF"
        "-DUSE_FSAL_MEM=OFF"
        "-DUSE_FSAL_SAUNAFS=OFF"
        "-DUSE_9P=OFF"
        "-DUSE_RQUOTA=OFF"
        "-DUSE_NFS3=ON"
        # Must stay ON: the stats tables (optnlm, optmnt, *_stats_time, the
        # reset_*_stats functions) are only compiled under USE_DBUS, but they
        # are referenced unconditionally from the NLM/NFS3 stats paths.
        # USE_DBUS=OFF simply does not compile upstream.
        "-DUSE_DBUS=ON"
        "-DUSE_MONITORING=ON"
        "-DUSE_NFS_RDMA=OFF"
        "-DUSE_TLS=OFF"
        "-DUSE_MAN_PAGE=OFF"
        "-DUSE_ADMIN_TOOLS=OFF"
        "-DUSE_GUI_ADMIN_TOOLS=OFF"
        "-DRPCBIND=ON"
      ];
    in
    {
      packages.${system} = {
        default = self.packages.${system}.nfs-ganesha;

        nfs-ganesha = pkgs.stdenv.mkDerivation {
          pname = "nfs-ganesha-proxyv3";
          version = "15.2-ontap-readdir";

          # Build with:  nix build '.?submodules=1'
          # The ?submodules=1 matters -- src/libntirpc is a git submodule and
          # without it the tree arrives here empty.
          src = self;

          # Fail with something readable rather than letting cmake report a
          # missing CMakeLists.txt three hundred lines into its output.
          preConfigure = ''
            for sub in src/libntirpc src/libkmip; do
              if [ ! -f "$sub/CMakeLists.txt" ]; then
                echo "error: $sub is empty -- the submodules were not fetched." >&2
                echo "       Use a git+https flake ref with submodules=1; a" >&2
                echo "       github: ref cannot carry submodules." >&2
                exit 1
              fi
            done
            cd src
          '';

          nativeBuildInputs = nativeDeps;
          buildInputs = runtimeDeps;

          inherit cmakeFlags;

          # Ganesha's tree trips several -Werror-by-default diagnostics on
          # recent gcc that upstream has not caught up with yet.
          env.NIX_CFLAGS_COMPILE = toString [
            "-Wno-error"
            "-Wno-redundant-move"
          ];

          # ntirpc generates libntirpc.pc as "${prefix}/@CMAKE_INSTALL_LIBDIR@"
          # while LIBDIR is already absolute, yielding "${prefix}//nix/store/...".
          # nixpkgs' validatePkgConfig hook rejects that.
          postInstall = ''
            if [ -f $out/lib/pkgconfig/libntirpc.pc ]; then
              substituteInPlace $out/lib/pkgconfig/libntirpc.pc \
                --replace-quiet '=''${prefix}//' '=/'
            fi
          '';

          postFixup = ''
            patchelf --add-rpath $out/lib $out/bin/ganesha.nfsd
            patchelf --add-rpath $out/lib $out/lib/libganesha_nfsd.so* || true
          '';

          meta = {
            description = "nfs-ganesha with PROXY_V3, patched for ONTAP READDIR";
            mainProgram = "ganesha.nfsd";
            platforms = [ system ];
          };
        };
      };

      # Fast edit/compile/test loop: cmake straight out of the shell, no nix
      # rebuild per iteration.
      devShells.${system}.default = pkgs.mkShell {
        packages = nativeDeps ++ runtimeDeps ++ [ pkgs.gdb pkgs.tshark ];
        shellHook = ''
          export GANESHA_CMAKE_FLAGS="${toString cmakeFlags}"
        '';
      };
    };
}
