{ fetchurl }:

let
  version = "1.5.7";
in fetchurl {
  name = "zstd-${version}.tar.gz";
  url = "https://github.com/facebook/zstd/archive/v${version}.tar.gz";
  hash = "sha256-N9coRVayCVTlbhyoW4AiZ2iQLi7avTtknp5ywMkBLuM=";
}
