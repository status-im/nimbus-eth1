{ fetchurl }:

let
  version = "1.3.2";
in fetchurl {
  name = "zlib-${version}.tar.gz";
  url = "http://zlib.net/zlib-${version}.tar.gz";
  hash = "sha256-uzKaCizQJ00FUZ1hxmfAYuBpkNcuEl7i36jeZPARnRY=";
}
