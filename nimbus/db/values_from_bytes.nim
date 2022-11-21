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
