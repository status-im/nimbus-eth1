{
  pkgs ? import <nixpkgs> { },
  # Source code of this repo.
  src ? ../.,
  # Nimbus-build-system package.
  nim ? null,
  # Options: nimbus, nimbus_execution_client, nimbus_portal_client, nimbus_portal_bridge
  targets ? ["nimbus_execution_client"],
  # Options: 0,1,2
  verbosity ? 2,
  # FIXME: Necessary to compile EL client without linker failures.
  disableLto ? true,
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

  revision = lib.substring 0 8 (src.rev or src.dirtyRev or "00000000");
in stdenv.mkDerivation rec {
  pname = "nimbus-eth1";
  version = "${callPackage ./version.nix {}}-${revision}";

  inherit src;

  # Fix for Nim compiler calling 'git rev-parse' and 'lsb_release'.
  nativeBuildInputs = let
    fakeGit = writeScriptBin "git" "echo ${version}";
    fakeLsbRelease = writeScriptBin "lsb_release" "echo nix";
  in
    with pkgs; [ nim rocksdb fakeGit fakeLsbRelease perl which ]
    ++ lib.optionals stdenv.isDarwin [ pkgs.darwin.cctools ];

  #enableParallelBuilding = true;
  enableParallelBuilding = false;

  env = {
    # Disable CPU optmizations that make binary not portable.
    NIMFLAGS = "-d:disableMarchNative -d:git_revision_override=${revision}";
    NIM_PARAMS = lib.optionalString disableLto " --passC:'-fno-lto' --passL:'-fno-lto'";

    # Avoid Nim cache permission errors.
    XDG_CACHE_HOME = "/tmp";

    #NIX_DEBUG = 7;
    #NIX_CFLAGS_COMPILE = " -fno-lto";
    #NIX_CFLAGS_LINK = " -Wl,-plugin-opt=-disable-lto";
    #NIX_CFLAGS_LINK = ''
    #  -Wl,--verbose
    #  -Wl,-plugin-opt=-debug
    #  -Wl,-plugin-opt=-save-temps
    #  -Wl,-plugin-opt=-v
    #  -Wl,-Map,link.map
    #'';
  };

  makeFlags = targets ++ [
    "V=${toString verbosity}"
    "NIM_PARAMS=$NIM_PARAMS"
    # Built from nimbus-build-system via flake.
    "USE_SYSTEM_NIM=1"
    # FIXME: Building local RockDB fails silently.
    "USE_SYSTEM_ROCKSDB=1"
  ];

  patchPhase = ''
    patchShebangs scripts vendor
    # Avoid CA Cert download error
    sed -i '196,200d' vendor/nimbus-build-system/scripts/build_nim.sh
    mkdir bin
    cp ${pkgs.cacert}/etc/ssl/certs/ca-bundle.crt bin/cacert.pem
  '';

  # Generate the nimbus-build-system.paths file with vendor module paths.
  configurePhase = ''
    make nimbus-build-system-paths
  '';

  installPhase = ''
    mkdir -p $out/bin
    rm -f build/generate_makefile
    cp build/* $out/bin
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
