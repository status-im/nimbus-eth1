{ callPackage, fetchurl }:

let
  tools = callPackage ../tools.nix {};
  source = ../../vendor/nim-rocksdb/vendor/rocksdb/Makefile;

  version = tools.findKeyValue "^LZ4_VER \\?= ([0-9.]+)$" source;
in fetchurl {
  name = "lz4-${version}.tar.gz";
  url = "https://github.com/lz4/lz4/archive/v${version}.tar.gz";
  hash = "sha256-U3USkEdEs14jKRIFXM+Oxm12hjn/Or5XiNkNeS7F9Is=";
}
