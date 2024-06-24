# Nimbus
# Copyright (c) 2018-2024 Status Research & Development GmbH
# Licensed under either of
#  * Apache License, version 2.0, ([LICENSE-APACHE](LICENSE-APACHE) or
#    http://www.apache.org/licenses/LICENSE-2.0)
#  * MIT license ([LICENSE-MIT](LICENSE-MIT) or
#    http://opensource.org/licenses/MIT)
# at your option. This file may not be copied, modified, or distributed except
# according to those terms.

import ../nimbus/evm/code_stream, strformat

var c =
  CodeStream.init(CodeBytesRef.fromHex("0x6003600202600055").expect("valid code"))

let opcodes = c.decompile()
for op in opcodes:
  echo &"[{op[0]}]\t{op[1]}\t{op[2]}"

# [1]     PUSH1   0x03
# [3]     PUSH1   0x02
# [4]     MUL
# [6]     PUSH1   0x00
# [7]     SSTORE
# [-1]    STOP
