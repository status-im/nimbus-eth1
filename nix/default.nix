{
  pkgs ? import <nixpkgs> { },
  # Flake source info.
  self ? {},
  # Nimbus-build-system package.
  nim ? null,
  # Options: nimbus, nimbus_execution_client, nimbus_portal_client, nimbus_portal_bridge, nimbus_verified_proxy
  targets ? ["nimbus_execution_client"],
  # Options: 0,1,2
  verbosity ? 1,
  # Building RocksDB from vendor takes almost double the time.
  dynamicRocksDB ? false,
  # These are the only platforms tested in CI and considered stable.
  stableSystems ? [
    "x86_64-linux" "aarch64-linux" "armv7a-linux"
    "x86_64-darwin" "aarch64-darwin"
    "x86_64-windows"
  ],
}:

# The 'or' is to handle self fallback to ../. which lack submodules attribue.
assert pkgs.lib.assertMsg ((self.submodules or true) == true)
  "Unable to build without submodules. Append '?submodules=1#' to the URI.";

let
  inherit (pkgs) stdenv lib writeScriptBin callPackage;
  inherit (lib) substring optionals optionalString makeLibraryPath;

  revision = substring 0 8 (self.rev or self.dirtyRev or "00000000");
in stdenv.mkDerivation rec {
  pname = "nimbus-eth1";
  version = "${callPackage ./version.nix {}}-${revision}";

  src = lib.fileset.toSource {
    root = ./..;
    fileset = lib.fileset.unions [
      ./../Makefile ./../nimbus.nimble ./../config.nims
      ./../execution_chain ./../nimbus_verified_proxy
      ./../portal ./../hive_integration
      ./../vendor ./../scripts ./../tools
    ];
  };

  enableParallelBuilding = false;

  buildInputs = with pkgs; [
    perl sqlite python3
  ] ++ optionals dynamicRocksDB [
    rocksdb
  ];

  runtimeDependencies = optionals dynamicRocksDB [ pkgs.rocksdb ];

  # Fix for Nim compiler calling 'git rev-parse' and 'lsb_release'.
  nativeBuildInputs = let
    fakeGit = writeScriptBin "git" "echo ${version}";
  in with pkgs; [
    nim which fakeGit
  ] ++ (if (!stdenv.isDarwin) then [
    lsb-release
  ] else [
    darwin.cctools
  ]);

  env = {
    # Disable CPU optmizations that make binary not portable.
    NIMFLAGS = "-d:disableMarchNative -d:git_revision_override=${revision}"
      + optionalString dynamicRocksDB " -d:rocksdb_dynamic_linking";
    NIX_LDFLAGS = optionalString dynamicRocksDB "-rpath ${makeLibraryPath [pkgs.rocksdb]}";
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

  # Copy RocksDB build from local vendor submodule.
  preBuild = optionalString (!dynamicRocksDB) (let
    rocksdb = callPackage ./rocksdb { };
  in ''
    mkdir -p vendor/nim-rocksdb/build/
    cp -v ${rocksdb}/lib/lib* vendor/nim-rocksdb/build/
    echo ${rocksdb.version} > vendor/nim-rocksdb/build/version.txt
  '');

  installPhase = ''
    mkdir -p $out/bin
    rm -rf build/generate_makefile build/*rocksdb*
    find build -type f -executable -exec install -Dt $out/bin {} \;
  '';

  doInstallCheck = true;
  installCheckPhase = ''
    for BINARY in $out/bin/*; do
      case "$(basename "$BINARY")" in
        # No support for --version.
        portal_bridge) $BINARY --help > /dev/null 2>&1;;
        *)             $BINARY --version ;;
      esac
    done
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
