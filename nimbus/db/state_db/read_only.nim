# Nimbus
# Copyright (c) 2018-2024 Status Research & Development GmbH
# Licensed under either of
#  * Apache License, version 2.0, ([LICENSE-APACHE](LICENSE-APACHE)
#    or http://www.apache.org/licenses/LICENSE-2.0)
#  * MIT license ([LICENSE-MIT](LICENSE-MIT)
#    or http://opensource.org/licenses/MIT)
# at your option. This file may not be copied, modified, or distributed
# except according to those terms.

import
  results,
  ../core_db,
  ./base

type
  ReadOnlyStateDB* = distinct AccountStateDB

#proc getTrie*(db: ReadOnlyStateDB): CoreDbMptRef {.borrow.}
proc db*(db: ReadOnlyStateDB): CoreDbRef {.borrow.}
proc rootHash*(db: ReadOnlyStateDB): KeccakHash {.borrow.}
proc getAccount*(db: ReadOnlyStateDB, address: EthAddress): CoreDbAccount {.borrow.}
proc getCodeHash*(db: ReadOnlyStateDB, address: EthAddress): Hash256 {.borrow.}
proc getBalance*(db: ReadOnlyStateDB, address: EthAddress): UInt256 {.borrow.}
proc getStorageRoot*(db: ReadOnlyStateDB, address: EthAddress): Hash256 {.borrow.}
proc getStorage*(db: ReadOnlyStateDB, address: EthAddress, slot: UInt256): Result[UInt256,void] {.borrow.}
proc getNonce*(db: ReadOnlyStateDB, address: EthAddress): AccountNonce {.borrow.}
proc getCode*(db: ReadOnlyStateDB, address: EthAddress): seq[byte] {.borrow.}
proc contractCollision*(db: ReadOnlyStateDB, address: EthAddress): bool {.borrow.}
proc accountExists*(db: ReadOnlyStateDB, address: EthAddress): bool {.borrow.}
proc isDeadAccount*(db: ReadOnlyStateDB, address: EthAddress): bool {.borrow.}
proc isEmptyAccount*(db: ReadOnlyStateDB, address: EthAddress): bool {.borrow.}
#proc getAccountProof*(db: ReadOnlyStateDB, address: EthAddress): AccountProof {.borrow.}
#proc getStorageProof*(db: ReadOnlyStateDB, address: EthAddress, slots: seq[UInt256]): seq[SlotProof] {.borrow.}
#proc getCommittedStorage*(db: ReadOnlyStateDB, address: EthAddress, slot: UInt256): UInt256 {.borrow.}

# End
