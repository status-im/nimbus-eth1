# based on https://github.com/nim-lang/Nim/blob/v0.18.0/.travis.yml

{ stdenv, lib, makeWrapper, git, clang, nodejs, openssl, pcre, readline,
  boehmgc, sfml, sqlite }:

let
  csources = fetchTarball {
    url = https://github.com/nim-lang/csources/archive/b56e49bbedf62db22eb26388f98262e2948b2cbc.tar.gz;
    sha256 = "00mzzhnp1myjbn3rw8qfnz593phn8vmcffw2lf1r2ncppck5jbpj";
  };

  nimble = fetchTarball {
    url = https://github.com/nim-lang/nimble/archive/3d6dc90cd4dfc12b8ae9d1958e84610cf21b34bb.tar.gz;
    sha256 = "19zmimnrwyhj59dfac9q7z1mrb65439sqzhvfz8bvxa1ibzws5lz";
  };

in stdenv.mkDerivation rec {
  # This derivation may be a bit confusing at first, because it builds the Status'
  # Nimbus branch of Nim using the standard Nim compiler provided by Nix.
  #
  # It's mostly a copy of the original Nim recipe, but uses git to obtain the
  # sources and have a simplified `buildPhase`.
  #
  # For maintainance, you only need to bump the obtained git revision from time
  # to time.

  name = "status-nim";
  version = "0.19.0";

  src = fetchTarball {
    url = https://github.com/status-im/Nim/archive/c240806756579c3375b1a79e1e65c40087a52ac5.tar.gz;
    sha256 = "1fa1ca145qhi002zj1a4kcq6ihxnyjzq1c5ys7adz796m7g5jw7i";
  };

  doCheck = true;

  enableParallelBuilding = true;

  NIX_LDFLAGS = [
    "-lcrypto"
    "-lpcre"
    "-lreadline"
    "-lsqlite3"
  ];

  # 1. nodejs is only needed for tests
  # 2. we could create a separate derivation for the "written in c" version of nim
  #    used for bootstrapping, but koch insists on moving the nim compiler around
  #    as part of building it, so it cannot be read-only

  nativeBuildInputs = [
    makeWrapper
  ];

  buildInputs = [
    nodejs git
    clang openssl pcre readline boehmgc sfml sqlite
  ];

  buildPhase = ''
    export HOME=$TMP
    mkdir -p dist
    cp -r ${nimble} dist/nimble
    cp -r ${csources} csources
    chmod 755 $(find csources dist/nimble -type d)
    cd csources
    CC="clang" LD="clang" sh build.sh
    cd ..
    bin/nim c --cc:clang -d:release koch.nim
    ./koch boot --cc:clang -d:release
    ./koch tools --cc:clang -d:release
  '';

  installPhase = ''
    install -Dt $out/bin bin/* koch
    ./koch install $out
    mv $out/nim/bin/* $out/bin/ && rmdir $out/nim/bin
    mv $out/nim/*     $out/     && rmdir $out/nim
    wrapProgram $out/bin/nim \
      --suffix PATH : ${lib.makeBinPath [ stdenv.cc ]}
  '';

  meta = with stdenv.lib; {
    description = "Status's build of Nim";
    homepage = https://nim-lang.org/;
    license = licenses.mit;
    maintainers = with maintainers; [ ehmry peterhoeg ];
    platforms = with platforms; linux ++ darwin; # arbitrary
  };
}

