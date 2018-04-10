# Nimbus
# Copyright (c) 2018 Status Research & Development GmbH
# Licensed under either of
#  * Apache License, version 2.0, ([LICENSE-APACHE](LICENSE-APACHE) or http://www.apache.org/licenses/LICENSE-2.0)
#  * MIT license ([LICENSE-MIT](LICENSE-MIT) or http://opensource.org/licenses/MIT)
# at your option. This file may not be copied, modified, or distributed except according to those terms.

import
  constants, errors, ttmath, rlp

type
  Account* = ref object
    nonce*:             UInt256
    balance*:           UInt256
    storageRoot*:       string
    codeHash*:          string

rlpFields Account, nonce, balance

proc newAccount*(nonce: UInt256 = 0.u256, balance: UInt256 = 0.u256): Account =
  Account(nonce: nonce, balance: balance)
