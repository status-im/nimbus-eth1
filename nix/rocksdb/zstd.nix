{ callPackage, fetchurl }:

let
  tools = callPackage ../tools.nix {};
  source = ../../vendor/nim-rocksdb/vendor/rocksdb/Makefile;

  version = tools.findKeyValue "^ZSTD_VER \\?= ([0-9.]+)$" source;
in fetchurl {
  name = "zstd-${version}.tar.gz";
  url = "https://github.com/facebook/zstd/archive/v${version}.tar.gz";
  hash = "sha256-N9coRVayCVTlbhyoW4AiZ2iQLi7avTtknp5ywMkBLuM=";
}
