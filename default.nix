let
  pkgs = import (fetchTarball {
    url = https://github.com/NixOS/nixpkgs/archive/642499faefb17c3d36e074cf35b189f75ba43ee2.tar.gz;
    sha256 = "16j7gl3gg839fy54z5v4aap8lgf1ffih5swmfk62zskk30nwzfbi";
  }) {};

in

import ./nix/nimbus.nix { inherit pkgs; }

