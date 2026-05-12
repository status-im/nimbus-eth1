{
  pkgs,
  debug ? 0,
}:

let
  inherit (pkgs) stdenv lib writeScriptBin callPackage;

  version = callPackage ./version.nix { };
in stdenv.mkDerivation rec {
  pname = "rocksdb";
  inherit version;

  src = ../../vendor/nim-rocksdb/vendor/rocksdb;

  enableParallelBuilding = true;

  nativeBuildInputs = let
    fakeHostname = writeScriptBin "hostname" "echo nix";
  in with pkgs; [
    which perl fakeHostname
  ];

  makeFlags = [
    # Compression libraries required for nimbus-eth1.
    "liblz4.a" "libzstd.a"
    "PREFIX=$(out)"
    "DEBUG_LEVEL=${toString debug}"
  ];

  # Fix: util/compression.cc:1367:40: error: unused parameter 'args'
  NIX_CFLAGS_COMPILE = "-Wno-unused-parameter";

  patchPhase = ''
    patchShebangs build_tools >/dev/null
  '';

  preBuild = let
    # These are RocksDB dependencies that Makefile tries to download.
    zstd = callPackage ./zstd.nix { };
    zlib = callPackage ./zlib.nix { };
    lz4 = callPackage ./lz4.nix { };
  in ''
    cp -v ${zlib} ${zlib.name}
    cp -v ${zstd} ${zstd.name}
    cp -v ${lz4}  ${lz4.name}
  '';

  # Nimbus build requires compression libs too.
  postInstall = ''
    cp -v liblz4.a libzstd.a $out/lib
  '';

  meta = with lib; {
    homepage = "https://rocksdb.org/";
    description = "Library that provides an embeddable, persistent key-value store for fast storage";
    license = lib.licenses.asl20;
    platforms = lib.platforms.all;
  };
}
