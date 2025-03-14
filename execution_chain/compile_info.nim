# Nimbus
# Copyright (c) 2021-2025 Status Research & Development GmbH
# Licensed under either of
#  * Apache License, version 2.0, ([LICENSE-APACHE](LICENSE-APACHE) or
#    http://www.apache.org/licenses/LICENSE-2.0)
#  * MIT license ([LICENSE-MIT](LICENSE-MIT) or
#    http://opensource.org/licenses/MIT)
# at your option. This file may not be copied, modified, or distributed except
# according to those terms.

{.push raises: [].}

const
  chronicles_line_numbers {.strdefine.} = "0"
  warningMsg = block:
    var rc = "*** Compiling with nimvm"
    if chronicles_line_numbers notin ["0", "off"]:
      rc &= ", logger line numbers"
    rc & " enabled"

{.warning: warningMsg.}

{.used.}
