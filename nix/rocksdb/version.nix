{ callPackage }:

let
  tools = callPackage ../tools.nix {};
  source = ../../vendor/nim-rocksdb/vendor/rocksdb/include/rocksdb/version.h;

  major = tools.findKeyValue "#define ROCKSDB_MAJOR ([0-9]+)$" source;
  minor = tools.findKeyValue "#define ROCKSDB_MINOR ([0-9]+)$" source;
  build = tools.findKeyValue "#define ROCKSDB_PATCH ([0-9]+)$" source;
in
  "${major}.${minor}.${build}"
