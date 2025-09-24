# Nimbus
# Copyright (c) 2021-2025 Status Research & Development GmbH
# Licensed under either of
#  * Apache License, version 2.0, ([LICENSE-APACHE](LICENSE-APACHE))
#  * MIT license ([LICENSE-MIT](LICENSE-MIT))
# at your option.
# This file may not be copied, modified, or distributed except according to
# those terms.

{.push raises: [].}

import std/[strutils, os], stew/[io2, byteutils], results, eth/common/keys

proc containsOnlyHexDigits(hex: string): bool =
  const HexDigitsX = HexDigits + {'x'}
  for c in hex:
    if c notin HexDigitsX:
      return false
  true

proc getNetKeys*(rng: var HmacDrbgContext, netKey: string): Result[KeyPair, string] =
  let privateKey =
    if netKey.len == 0 or netKey == "random":
      PrivateKey.random(rng)
    elif netKey.len in {64, 66} and netKey.containsOnlyHexDigits:
      PrivateKey.fromHex(netKey).valueOr:
        return err($error)
    else:
      # TODO: should we secure the private key with
      # keystore encryption?
      if fileAccessible(netKey, {AccessFlags.Find}):
        try:
          let lines = netKey.readLines(1)
          if lines.len == 0:
            return err("empty network key file")
          PrivateKey.fromHex(lines[0]).valueOr:
            return err($error)
        except IOError as e:
          return err("cannot open network key file: " & e.msg)
      else:
        let privateKey = PrivateKey.random(rng)

        try:
          createDir(netKey.splitFile.dir)
          netKey.writeFile(privateKey.toRaw.to0xHex)
        except OSError as e:
          return err("could not create network key file: " & e.msg)
        except IOError as e:
          return err("could not write network key file: " & e.msg)

        privateKey
  ok privateKey.toKeyPair()
