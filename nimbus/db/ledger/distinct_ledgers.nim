# Nimbus
# Copyright (c) 2023 Status Research & Development GmbH
# Licensed under either of
#  * Apache License, version 2.0, ([LICENSE-APACHE](LICENSE-APACHE) or
#    http://www.apache.org/licenses/LICENSE-2.0)
#  * MIT license ([LICENSE-MIT](LICENSE-MIT) or
#    http://opensource.org/licenses/MIT)
# at your option. This file may not be copied, modified, or distributed except
# according to those terms.

# The point of this file is just to give a little more type-safety
# and clarity to our use of SecureHexaryTrie, by having distinct
# types for the big trie containing all the accounts and the little
# tries containing the storage for an individual account.
#
# It's nice to have all the accesses go through "getAccountBytes"
# rather than just "get" (which is hard to search for). Plus we
# may want to put in assertions to make sure that the nodes for
# the account are all present (in stateless mode), etc.

{.push raises: [].}

## Re-write of `distinct_tries.nim` to be imported into `accounts_ledger.nim`
## for using new database API.
##

import
  std/[algorithm, sequtils, strutils, tables, typetraits],
  chronicles,
  eth/common,
  results,
  ".."/[core_db, storage_types]

type
  AccountLedger* = distinct CoreDxAccRef
  StorageLedger* = distinct CoreDxPhkRef
  SomeLedger* = AccountLedger | StorageLedger

# ------------------------------------------------------------------------------
# Public debugging helpers
# ------------------------------------------------------------------------------

proc toSvp*(sl: StorageLedger): seq[(UInt256,UInt256)] =
  ## Dump as slot id-value pair sequence
  let
    db = sl.distinctBase.parent
    save = db.trackNewApi
  db.trackNewApi = false
  defer: db.trackNewApi = save
  let kvt = db.newKvt
  var kvp: Table[UInt256,UInt256]
  try:
    for (slotHash,val) in sl.distinctBase.toMpt.pairs:
      let rc = kvt.get(slotHashToSlotKey(slotHash).toOpenArray)
      if rc.isErr:
        warn "StorageLedger.dump()", slotHash, error=($$rc.error)
      else:
        kvp[rlp.decode(rc.value,UInt256)] = rlp.decode(val,UInt256)
  except CatchableError as e:
    raiseAssert "Ooops(" & $e.name & "): " & e.msg
  kvp.keys.toSeq.sorted.mapIt((it,kvp.getOrDefault(it,high UInt256)))

proc toStr*(w: seq[(UInt256,UInt256)]): string =
  "[" & w.mapIt("(" & it[0].toHex & "," & it[1].toHex & ")").join(", ") & "]"

# ------------------------------------------------------------------------------
# Public helpers
# ------------------------------------------------------------------------------

proc db*(t: SomeLedger): CoreDbRef =
  t.distinctBase.parent

proc rootHash*(t: SomeLedger): Hash256 =
  t.distinctBase.rootVid().hash(update=true).expect "SomeLedger/rootHash()"

proc rootVid*(t: SomeLedger): CoreDbVidRef =
  t.distinctBase.rootVid

# ------------------------------------------------------------------------------
# Public functions: accounts ledger
# ------------------------------------------------------------------------------

proc init*(
    T: type AccountLedger;
    db: CoreDbRef;
    rootHash: Hash256;
    isPruning = true;
      ): T =
  let vid = db.getRoot(rootHash).expect "AccountLedger/getRoot()"
  db.newAccMpt(vid, isPruning).T

proc init*(
    T: type AccountLedger;
    db: CoreDbRef;
    isPruning = true;
      ): T =
  db.newAccMpt(CoreDbVidRef(nil), isPruning).AccountLedger

proc fetch*(al: AccountLedger; eAddr: EthAddress): Result[CoreDbAccount,void] =
  ## Using `fetch()` for trie data retrieval
  al.distinctBase.fetch(eAddr).mapErr(proc(ign: CoreDbErrorRef) = discard)

proc merge*(al: AccountLedger; eAddr: EthAddress; account: CoreDbAccount) =
  ## Using `merge()` for trie data storage
  al.distinctBase.merge(eAddr, account).expect "AccountLedger/merge()"

proc delete*(al: AccountLedger, eAddr: EthAddress) =
  al.distinctBase.delete(eAddr).expect "AccountLedger/delete()"

# ------------------------------------------------------------------------------
# Public functions: storage ledger
# ------------------------------------------------------------------------------

proc init*(
    T: type StorageLedger;
    al: AccountLedger;
    account: CoreDbAccount;
    isPruning = false;
      ): T =
  ## Storage trie constructor.
  ##
  ## Note that the argument `isPruning` should be left `false` on the legacy
  ## `CoreDb` backend. Otherwise, pruning might kill some unwanted entries from
  ## storage tries ending up with an unstable database leading to crashes (see
  ## https://github.com/status-im/nimbus-eth1/issues/932.)
  al.distinctBase.parent.newMpt(account.storageVid, isPruning).toPhk.T

#proc init*(T: type StorageLedger; db: CoreDbRef, isPruning = false): T =
#  db.newMpt(CoreDbVidRef(nil), isPruning).toPhk.T

proc fetch*(sl: StorageLedger, slot: UInt256): Result[Blob,void] =
  sl.distinctBase.fetch(slot.toBytesBE).mapErr proc(ign: CoreDbErrorRef)=discard

proc merge*(sl: StorageLedger, slot: UInt256, value: openArray[byte]) =
  sl.distinctBase.merge(slot.toBytesBE, value).expect "StorageLedger/merge()"

proc delete*(sl: StorageLedger, slot: UInt256) =
  sl.distinctBase.delete(slot.toBytesBE).expect "StorageLedger/delete()"

iterator storage*(
    al: AccountLedger;
    account: CoreDbAccount;
      ): (Blob,Blob)
      {.gcsafe, raises: [CoreDbApiError].} =
  ## For given account, iterate over storage slots
  for (key,val) in al.distinctBase.parent.newMpt(account.storageVid).pairs:
    yield (key,val)

# ------------------------------------------------------------------------------
# End
# ------------------------------------------------------------------------------
