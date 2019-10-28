{ stdenv, callPackage, sqlite, clang, pcre, rocksdb }:

let
  nim = callPackage ./nim.nix {};
  makeLibraryPath = stdenv.lib.makeLibraryPath;

in

stdenv.mkDerivation rec {
  name = "nimbus-${version}";
  version = "0.0.1";

  meta = with stdenv.lib; {
    description = "An Ethereum 2.0 Sharding Client for Resource-Restricted Devices";
    homepage = https://github.com/status-im/nimbus;
    license = [licenses.asl20];
    platforms = platforms.unix ++ platforms.windows;
  };

  src = ./.;
  buildInputs = [clang nim rocksdb pcre sqlite];
  LD_LIBRARY_PATH = "${makeLibraryPath buildInputs}";
}

