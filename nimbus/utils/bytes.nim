# Nimbus
# Copyright (c) 2018 Status Research & Development GmbH
# Licensed under either of
#  * Apache License, version 2.0, ([LICENSE-APACHE](LICENSE-APACHE) or http://www.apache.org/licenses/LICENSE-2.0)
#  * MIT license ([LICENSE-MIT](LICENSE-MIT) or http://opensource.org/licenses/MIT)
# at your option. This file may not be copied, modified, or distributed except according to those terms.

import strutils, sequtils

# proc toBytes*(value: cstring): seq[byte] =
#   result = newSeq[byte](value.len)
#   for z, c in value:
#     result[z] = c.byte
#   # result = toSeq(value)

# proc toCString*(value: seq[byte]): cstring =
#   var res = ""
#   for c in value:
#     res.add(c.char)
#   cstring(res) # TODO: faster

proc toString*(value: seq[byte]): string =
  "0x" & value.mapIt(it.int.toHex(2)).join("").toLowerAscii

proc toBytes*(value: string): seq[byte] =
  result = value.mapIt(it.byte)


