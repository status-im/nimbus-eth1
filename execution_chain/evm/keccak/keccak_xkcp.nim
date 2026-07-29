# Nimbus
# Copyright (c) 2026 Status Research & Development GmbH
# Licensed under either of
#  * Apache License, version 2.0, ([LICENSE-APACHE](LICENSE-APACHE) or
#    http://www.apache.org/licenses/LICENSE-2.0)
#  * MIT license ([LICENSE-MIT](LICENSE-MIT) or
#    http://opensource.org/licenses/MIT)
# at your option. This file may not be copied, modified, or distributed except
# according to those terms.

## Keccak-256 for the EVM KECCAK256 opcode, using an XKCP-style permutation.
##
## `eth/common/hashes.keccak256` dispatches to nim-eth's vendored BoringSSL C,
## whose permutation applies rho/pi in place along a 24-step trail -- a serial
## dependency chain. This one writes the rotations into a second lane set so
## they are independent; see the accompanying `keccak_xkcp.c` for detail.
##
## Scope is deliberately just the opcode. Everything else in the client still
## goes through `eth/common/hashes`, so this changes one call site rather than
## every hash in the system.

{.push raises: [], gcsafe.}

import
  std/[os, strutils],
  eth/common/hashes

const srcPath = currentSourcePath.rsplit({DirSep, AltSep}, 1)[0]

{.compile: srcPath & "/keccak_xkcp.c".}

func keccak256_xkcp(inp: ptr byte, inLen: csize_t, output: ptr byte) {.cdecl,
  importc: "keccak256_xkcp".}

func keccak256Xkcp*(data: openArray[byte]): Hash32 =
  ## One-shot Keccak-256. Callers with an empty input should prefer the
  ## `emptyKeccak256` constant; this still returns the correct digest for it,
  ## but pays a full permutation to do so.
  let inp: ptr byte =
    if data.len == 0: nil
    else: unsafeAddr data[0]
  keccak256_xkcp(inp, csize_t(data.len), addr result.data[0])

{.pop.}
