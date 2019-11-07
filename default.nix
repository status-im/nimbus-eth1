let
  nixpkgsFn = import (fetchTarball {
    url = https://github.com/NixOS/nixpkgs/archive/85f3d86bea70fe0d76a7e3520966c58604f8e5e9.tar.gz;
    sha256 = "1iacnd7ym6c5s9vizyiff0lmxjrlgh5gpya88mlavgvdppkcaiyn";
  });

  # nixcrpkgs = import (fetchTarball {
  #  url = https://github.com/DavidEGrayson/nixcrpkgs/archive/606e5fac74204643c8ca48dd73ce239b2f821d69.tar.gz;
  #  sha256 = "19dn7i200xsv8s92kxymv3nd87jncmp3ki8pw77v2rxfvn8ldg34";
  # }) {};

  nixpkgs = nixpkgsFn {};

  targets = {
    windows = {
      config = "x86_64-pc-mingw32";
      libc = "msvcrt";
      platform = {};
      openssl.system = "mingw";
    };

    iphone = {
      config = "aarch64-apple-ios";
      # config = "aarch64-apple-darwin14";
      sdkVer = "10.2";
      xcodeVer = "8.2";
      xcodePlatform = "iPhoneOS";
      useiOSPrebuilt = true;
      platform = {};
    };

    android = {
      config = "armv7a-unknown-linux-androideabi";
      sdkVer = "24";
      ndkVer = "18b";
      platform = nixpkgs.platforms.armv7a-android;
      useAndroidPrebuilt = true;
    };

    raspberryPi = rec {
      config = "armv6l-unknown-linux-gnueabihf";
      platform = nixpkgs.platforms.raspberrypi;
    };

    raspberryPi2 = {
      config = "armv7l-unknown-linux-gnueabihf";
      platform = nixpkgs.platforms.armv7l-hf-multiplatform;
    };
  };

  nimbus = pkgs: pkgs.callPackage ./nix/nimbus.nix {};

  inherit (nixpkgs.lib.attrsets) mapAttrs;
  crossPackages = mapAttrs (target: conf: nixpkgsFn { crossSystem = conf; }) targets;
  crossBuilds = mapAttrs (target: packages: nimbus packages) crossPackages;

in
  (nimbus nixpkgs) //
  crossBuilds //
  { 
    wrappers = nixpkgs.callPackage ./nix/nimbus-wrappers.nix {};
  }
