# Nimbus
# Copyright (c) 2023-2024 Status Research & Development GmbH
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
  StorageLedger* = distinct CoreDxMptRef
  SomeLedger* = AccountLedger | StorageLedger

const
  EnableMptDump = false # or true
    ## Provide database dumper. Note that the dump function needs to link
    ## against the `rocksdb` library. The# dependency lies in import of
    ## `aristo_debug`.

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
    for (slotHash,val) in sl.distinctBase.pairs:
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

when EnableMptDump:
  import
    eth/trie,
    stew/byteutils,
    ../aristo,
    ../aristo/aristo_debug

  proc dump*(led: SomeLedger): string =
    ## Dump database (beware of large backend)
    let db = led.distinctBase.parent
    if db.dbType notin CoreDbPersistentTypes:
      # Memory based storage only
      let be = led.distinctBase.backend

      if db.isAristo:
        let adb = be.toAristo()
        if not adb.isNil:
          return adb.pp(kMapOk=false,backendOK=true)

    # Oops
    "<" & $db.dbType & ">"

# ------------------------------------------------------------------------------
# Public helpers
# ------------------------------------------------------------------------------

proc db*(led: SomeLedger): CoreDbRef =
  led.distinctBase.parent

proc state*(led: SomeLedger): Hash256 =
  when SomeLedger is AccountLedger:
    const info = "AccountLedger/state(): "
  else:
    const info = "StorageLedger/state(): "
  let rc = led.distinctBase.getColumn().state()
  if rc.isErr:
    raiseAssert info & $$rc.error
  rc.value

proc getColumn*(led: SomeLedger): CoreDbColRef =
  led.distinctBase.getColumn()

# ------------------------------------------------------------------------------
# Public functions: accounts ledger
# ------------------------------------------------------------------------------

proc init*(
    T: type AccountLedger;
    db: CoreDbRef;
    root: Hash256;
      ): T =
  const
    info = "AccountLedger.init(): "
  let
    ctx = db.ctx
    col = block:
      let rc = ctx.newColumn(CtAccounts, root)
      if rc.isErr:
        raiseAssert info & $$rc.error
      rc.value
    mpt =  block:
      let rc = ctx.getAcc(col)
      if rc.isErr:
        raiseAssert info & $$rc.error
      rc.value
  mpt.T

proc fetch*(al: AccountLedger; eAddr: EthAddress): Result[CoreDbAccount,void] =
  ## Using `fetch()` for trie data retrieval
  let rc = al.distinctBase.fetch(eAddr)
  if rc.isErr:
    return err()
  ok rc.value

proc merge*(al: AccountLedger; account: CoreDbAccount) =
  ## Using `merge()` for trie data storage
  const info =  "AccountLedger/merge(): "
  al.distinctBase.merge(account).isOkOr:
    raiseAssert info & $$error

proc freeStorage*(al: AccountLedger, eAddr: EthAddress) =
  const info = "AccountLedger/freeStorage()"
  # Flush associated storage trie
  al.distinctBase.stoDelete(eAddr).isOkOr:
    raiseAssert info & $$error

proc delete*(al: AccountLedger, eAddr: EthAddress) =
  const info = "AccountLedger/delete()"
  # Delete account and associated storage tree (if any)
  al.distinctBase.delete(eAddr).isOkOr:
    if error.error == MptNotFound:
      return
    raiseAssert info & $$error

# ------------------------------------------------------------------------------
# Public functions: storage ledger
# ------------------------------------------------------------------------------

proc init*(
    T: type StorageLedger;
    al: AccountLedger;
    account: CoreDbAccount;
      ): T =
  ## Storage trie constructor.
  ##
  const
    info = "StorageLedger/init(): "
  let
    db = al.distinctBase.parent
    stt = account.storage
    ctx = db.ctx
    trie = if stt.isNil: ctx.newColumn(account.address) else: stt
    mpt = block:
      let rc = ctx.getMpt(trie)
      if rc.isErr:
        raiseAssert info & $$rc.error
      rc.value
  mpt.T

proc fetch*(sl: StorageLedger, slot: UInt256): Result[Blob,void] =
  var rc = sl.distinctBase.fetch(slot.toBytesBE.keccakHash.data)
  if rc.isErr:
    return err()
  ok move(rc.value)

proc merge*(sl: StorageLedger, slot: UInt256, value: openArray[byte]) =
  const info = "StorageLedger/merge(): "
  sl.distinctBase.merge(slot.toBytesBE.keccakHash.data, value).isOkOr:
    raiseAssert info & $$error

proc delete*(sl: StorageLedger, slot: UInt256) =
  const info = "StorageLedger/delete(): "
  sl.distinctBase.delete(slot.toBytesBE.keccakHash.data).isOkOr:
    if error.error == MptNotFound:
      return
    raiseAssert info & $$error

iterator storage*(
    al: AccountLedger;
    account: CoreDbAccount;
      ): (Blob,Blob) =
  ## For given account, iterate over storage slots
  const
    info = "storage(): "
  let col = account.storage
  if not col.isNil:
    let mpt = al.distinctBase.parent.ctx.getMpt(col).valueOr:
      raiseAssert info & $$error
    for (key,val) in mpt.pairs:
      yield (key,val)

# ------------------------------------------------------------------------------
# End
# ------------------------------------------------------------------------------
