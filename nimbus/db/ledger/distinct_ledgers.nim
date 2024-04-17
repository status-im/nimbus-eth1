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
  StorageLedger* = distinct CoreDxPhkRef
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

      if db.isLegacy:
        let ldb = be.toLegacy()
        var blurb: seq[string]
        blurb.add "level=" & $db.level
        try:
          for (k,v) in ldb.pairs:
            let key = HashKey.fromBytes(k).value
            if key.isValid:
              let acc = rlp.decode(v, Account)
              blurb.add "(" & key.pp & ",(" &
                $acc.nonce & "," &
                $acc.balance & "," &
                acc.storageRoot.pp & "," &
                acc.codeHash.pp(codeHashOk=true) & "))"
        except RlpError as e:
          raiseAssert "dump: " & $e.name & " - " & e.msg
        return blurb.join("\n    ")

    # Oops
    "<" & $db.dbType & ">"

# ------------------------------------------------------------------------------
# Public helpers
# ------------------------------------------------------------------------------

proc db*(led: SomeLedger): CoreDbRef =
  led.distinctBase.parent

proc rootHash*(led: SomeLedger): Hash256 =
  when SomeLedger is AccountLedger:
    const info = "AccountLedger/rootHash(): "
  else:
    const info = "StorageLedger/rootHash(): "
  let rc = led.distinctBase.getTrie().rootHash()
  if rc.isErr:
    raiseAssert info & $$rc.error
  rc.value

proc getTrie*(led: SomeLedger): CoreDbTrieRef =
  led.distinctBase.getTrie()

# ------------------------------------------------------------------------------
# Public functions: accounts ledger
# ------------------------------------------------------------------------------

proc init*(
    T: type AccountLedger;
    db: CoreDbRef;
    root: Hash256;
    pruneOk = true;
      ): T =
  const
    info = "AccountLedger.init(): "
  let
    ctx = db.ctx
    trie = block:
      let rc = ctx.newTrie(AccountsTrie, root)
      if rc.isErr:
        raiseAssert info & $$rc.error
      rc.value
    mpt =  block:
      let rc = ctx.getAcc(trie)
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

proc delete*(al: AccountLedger, eAddr: EthAddress) =
  const info = "AccountLedger/delete()"
  # Flush associated storage trie
  al.distinctBase.stoFlush(eAddr).isOkOr:
    raiseAssert info & $$error
  # Clear account
  al.distinctBase.delete(eAddr).isOkOr:
    if error.error == MptNotFound:
      return
    raiseAssert info & $$error

proc persistent*(al: AccountLedger) =
  let rc = al.distinctBase.persistent()
  if rc.isErr:
    if rc.error.error != AccTxPending:
      raiseAssert "persistent oops, error=" & $$rc.error
    discard al.distinctBase.getTrie.rootHash.valueOr:
      raiseAssert "re-hash oops, error=" & $$error

# ------------------------------------------------------------------------------
# Public functions: storage ledger
# ------------------------------------------------------------------------------

proc init*(
    T: type StorageLedger;
    al: AccountLedger;
    account: CoreDbAccount;
    reHashOk = true;
    pruneOk = false;
      ): T =
  ## Storage trie constructor.
  ##
  ## Note that the argument `pruneOk` should be left `false` on the legacy
  ## `CoreDb` backend. Otherwise, pruning might kill some unwanted entries from
  ## storage tries ending up with an unstable database leading to crashes (see
  ## https://github.com/status-im/nimbus-eth1/issues/932.)
  const
    info = "StorageLedger/init(): "
  let
    db = al.distinctBase.parent
    stt = account.stoTrie
  if not stt.isNil and reHashOk:
    let rc = al.distinctBase.getTrie.rootHash
    if rc.isErr:
      raiseAssert "re-hash oops, error=" & $$rc.error
  let
    ctx = db.ctx
    trie = if stt.isNil: ctx.newTrie(account.address) else: stt
    mpt = block:
      let rc = ctx.getMpt(trie, pruneOk)
      if rc.isErr:
        raiseAssert info & $$rc.error
      rc.value
  mpt.toPhk.T

proc fetch*(sl: StorageLedger, slot: UInt256): Result[Blob,void] =
  let rc = sl.distinctBase.fetch(slot.toBytesBE)
  if rc.isErr:
    return err()
  ok rc.value

proc merge*(sl: StorageLedger, slot: UInt256, value: openArray[byte]) =
  const info = "StorageLedger/merge(): "
  sl.distinctBase.merge(slot.toBytesBE, value).isOkOr:
    raiseAssert info & $$error

proc delete*(sl: StorageLedger, slot: UInt256) =
  const info = "StorageLedger/delete(): "
  sl.distinctBase.delete(slot.toBytesBE).isOkOr:
    if error.error == MptNotFound:
      return
    raiseAssert info & $$error

iterator storage*(
    al: AccountLedger;
    account: CoreDbAccount;
      ): (Blob,Blob)
      {.gcsafe, raises: [CoreDbApiError].} =
  ## For given account, iterate over storage slots
  const
    info = "storage(): "
  let trie = account.stoTrie
  if not trie.isNil:
    let mpt = al.distinctBase.parent.ctx.getMpt(trie).valueOr:
      raiseAssert info & $$error
    for (key,val) in mpt.pairs:
      yield (key,val)

# ------------------------------------------------------------------------------
# End
# ------------------------------------------------------------------------------
