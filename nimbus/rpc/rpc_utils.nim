# Nimbus
# Copyright (c) 2018 Status Research & Development GmbH
# Licensed under either of
#  * Apache License, version 2.0, ([LICENSE-APACHE](LICENSE-APACHE))
#  * MIT license ([LICENSE-MIT](LICENSE-MIT))
# at your option.
# This file may not be copied, modified, or distributed except according to
# those terms.

import hexstrings, nimcrypto, eth_common, byteutils

func strToAddress*(value: string): EthAddress = hexToPaddedByteArray[20](value)

func toHash*(value: array[32, byte]): Hash256 {.inline.} =
  result.data = value

func strToHash*(value: string): Hash256 {.inline.} =
  result = hexToPaddedByteArray[32](value).toHash
