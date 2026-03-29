{
  pkgs ? import <nixpkgs> { },
  # Source code of this repo.
  src ? ../.,
  # Nimbus-build-system package.
  nim ? null,
  # Options: nimbus, nimbus_execution_client, nimbus_portal_client, nimbus_portal_bridge
  targets ? ["nimbus_execution_client"],
  # Options: 0,1,2
  verbosity ? 1,
  # FIXME: Necessary to compile EL client without linker failures.
  disableLto ? true,
  # Building RocksDB from vendor takes almost double the time.
  dynamicRocksDB ? true,
  # These are the only platforms tested in CI and considered stable.
  stableSystems ? [
    "x86_64-linux" "aarch64-linux" "armv7a-linux"
    "x86_64-darwin" "aarch64-darwin"
    "x86_64-windows"
  ],
}:

# The 'or' is to handle src fallback to ../. which lack submodules attribue.
assert pkgs.lib.assertMsg ((src.submodules or true) == true)
  "Unable to build without submodules. Append '?submodules=1#' to the URI.";

let
  inherit (pkgs) stdenv lib writeScriptBin callPackage;
  inherit (lib) substring optionals optionalString makeLibraryPath;

  revision = substring 0 8 (src.rev or src.dirtyRev or "00000000");
in stdenv.mkDerivation rec {
  pname = "nimbus-eth1";
  version = "${callPackage ./version.nix {}}-${revision}";

  inherit src;

  #enableParallelBuilding = true;
  enableParallelBuilding = false;

  buildInputs = with pkgs; [
    perl sqlite python3
  ] ++ optionals dynamicRocksDB [
    lz4 zstd rocksdb
  ];

  runtimeDependencies = optionals dynamicRocksDB [ pkgs.rocksdb ];

  # Fix for Nim compiler calling 'git rev-parse' and 'lsb_release'.
  nativeBuildInputs = let
    fakeGit = writeScriptBin "git" "echo ${version}";
    fakeHostname = writeScriptBin "hostname" "echo nix";
  in with pkgs; [
    nim which fakeGit fakeHostname
  ] ++ (if (!stdenv.isDarwin) then [
    lsb-release inetutils
  ] else [
    pkgs.darwin.cctools
  ]);

  env = {
    # Disable CPU optmizations that make binary not portable.
    NIMFLAGS = "-d:disableMarchNative -d:git_revision_override=${revision}"
      + optionalString dynamicRocksDB " -d:rocksdb_dynamic_linking";
    NIX_LDFLAGS = optionalString dynamicRocksDB "-rpath ${makeLibraryPath [pkgs.rocksdb]}";

    # Provide runtime libraries for linking.
    LD_LIBRARY_PATH = makeLibraryPath buildInputs;

    # RocksDB fix for no Git command.
    FORCE_GIT_SHA = "missing";

    # Avoid Nim cache permission errors.
    XDG_CACHE_HOME = "/tmp";
  };

  # Allow RocksDB dynamic linking.
  dontPatchELF = dynamicRocksDB;

  makeFlags = targets ++ [
    "V=${toString verbosity}"
    # Built from nimbus-build-system via flake.
    "USE_SYSTEM_NIM=1"
  ] ++ optionals dynamicRocksDB [
    "USE_SYSTEM_ROCKSDB=1"
  ];

  patchPhase = ''
    patchShebangs scripts vendor >/dev/null
  '';

  # Generate the nimbus-build-system.paths file with vendor module paths.
  configurePhase = ''
    make nimbus-build-system-paths
  '';

  # Fix for RocksDB Makefile calling curl to fetch these sources.
  preBuild = optionalString (!dynamicRocksDB) (let
    zstd = callPackage ./zstd.nix { };
    zlib = callPackage ./zlib.nix { };
    lz4 = callPackage ./lz4.nix { };
  in ''
    sed -i '/clean_build_artifacts.sh/d' vendor/nim-rocksdb/scripts/build_static_deps.sh
    cp -v ${zlib} vendor/nim-rocksdb/vendor/rocksdb/${zlib.name}
    cp -v ${zstd} vendor/nim-rocksdb/vendor/rocksdb/${zstd.name}
    cp -v ${lz4} vendor/nim-rocksdb/vendor/rocksdb/${lz4.name}
  '');

  installPhase = ''
    mkdir -p $out/bin
    rm -f build/generate_makefile
    cp -r build/* $out/bin
  '';

  meta = with lib; {
    homepage = "https://nimbus.guide/";
    downloadPage = "https://github.com/status-im/nimbus-eth1/releases";
    changelog = "https://github.com/status-im/nimbus-eth1/blob/master/CHANGELOG.md";
    description = "Nimbus is a lightweight client for the Ethereum consensus layer";
    longDescription = ''
      Nimbus is an extremely efficient consensus layer client implementation.
      While it's optimised for embedded systems and resource-restricted devices --
      including Raspberry Pis, its low resource usage also makes it an excellent choice
      for any server or desktop (where it simply takes up fewer resources).
    '';
    license = with licenses; [asl20 mit];
    mainProgram = builtins.head targets;
    platforms = stableSystems;
  };
}
