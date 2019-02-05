# Nimbus
# Copyright (c) 2018 Status Research & Development GmbH
# Licensed under either of
#  * Apache License, version 2.0, ([LICENSE-APACHE](LICENSE-APACHE) or http://www.apache.org/licenses/LICENSE-2.0)
#  * MIT license ([LICENSE-MIT](LICENSE-MIT) or http://opensource.org/licenses/MIT)
# at your option. This file may not be copied, modified, or distributed except according to those terms.

import
  nimcrypto, strutils, eth/common

proc keccak*(value: openarray[byte]): Hash256 {.inline.} =
  keccak256.digest value

proc keccak*(value: string): Hash256 {.inline.} =
  keccak256.digest value

proc keccak*(value: cstring): Hash256 {.inline.} =
  # TODO: this is inefficient it allocates for the cstring -> string and then for string -> result
  keccak $value
