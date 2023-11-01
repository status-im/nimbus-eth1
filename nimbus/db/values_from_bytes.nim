# Nimbus
# Copyright (c) 2023 Status Research & Development GmbH
# Licensed under either of
#  * Apache License, version 2.0, ([LICENSE-APACHE](LICENSE-APACHE) or
#    http://www.apache.org/licenses/LICENSE-2.0)
#  * MIT license ([LICENSE-MIT](LICENSE-MIT) or
#    http://opensource.org/licenses/MIT)
# at your option. This file may not be copied, modified, or distributed except
# according to those terms.

# This code was duplicated enough times around the codebase
# that it seemed worth factoring it out.

import
  stint,
  eth/[common, rlp]

proc accountFromBytes*(accountBytes: seq[byte]): Account =
  if accountBytes.len > 0:
    rlp.decode(accountBytes, Account)
  else:
    newAccount()

proc slotValueFromBytes*(rec: seq[byte]): UInt256 =
  if rec.len > 0:
    rlp.decode(rec, UInt256)
  else:
    UInt256.zero()
