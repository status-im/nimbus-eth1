{
  stdenv,
  lib,
  callPackage,
  fetchurl,
}:

let
  tools = callPackage ../tools.nix {};
  source = ../../vendor/nim-rocksdb/scripts/build_static_deps.sh;

  version = tools.findKeyValue "^LIBURING_VERSION=([0-9.]+)$" source;
in stdenv.mkDerivation {
  pname = "liburing";
  inherit version;

  src = fetchurl {
    name = "liburing-${version}.tar.gz";
    url = "https://github.com/axboe/liburing/archive/refs/tags/liburing-${version}.tar.gz";
    hash = "sha256-X4CWQQiYHGrZecc18LSHfV9JkUwqBi+OiCgvJr9h3gw=";
  };

  enableParallelBuilding = true;

  # Upstream configure is hand written and rejects the flags Nix passes.
  configurePhase = ''
    ./configure --prefix=$out
  '';

  # Only the static library is needed by nim-rocksdb.
  buildPhase = ''
    make -j$NIX_BUILD_CORES -C src liburing.a
  '';

  installPhase = ''
    mkdir -p $out/lib $out/include
    cp -v src/liburing.a $out/lib/
    cp -rv src/include/* $out/include/
  '';

  meta = with lib; {
    homepage = "https://github.com/axboe/liburing";
    description = "Userspace library for the Linux io_uring API";
    license = licenses.lgpl21;
    platforms = platforms.linux;
  };
}
