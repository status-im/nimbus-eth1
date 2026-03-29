{ fetchurl }:

let
  version = "1.10.0";
in fetchurl {
  name = "lz4-${version}.tar.gz";
  url = "https://github.com/lz4/lz4/archive/v${version}.tar.gz";
  hash = "sha256-U3USkEdEs14jKRIFXM+Oxm12hjn/Or5XiNkNeS7F9Is=";
}
