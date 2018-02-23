let
  pkgs = import (builtins.fetchGit {
     url = git://github.com/NixOS/nixpkgs;
     rev = "8c6f9223d02c5123cbd364d6d56caca3c81416f0";
  }) {};

in

import ./default.nix { inherit pkgs; }

