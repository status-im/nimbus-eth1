{ callPackage, fetchurl }:

let
  tools = callPackage ../tools.nix {};
  source = ../../vendor/nim-rocksdb/vendor/rocksdb/Makefile;

  version = tools.findKeyValue "^ZLIB_VER \\?= ([0-9.]+)$" source;
in fetchurl {
  name = "zlib-${version}.tar.gz";
  url = "https://github.com/madler/zlib/releases/download/v${version}/zlib-${version}.tar.gz";
  hash = "sha256-mpOyt9/ax3zrpaVYpYDnRmfdb+3kWFuR7vtg8Dty3yM=";
}
