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

## Re-write of `distinct_tries.nim` to be imported into `accounts_cache.nim`
## for using new database API.
##

import
  std/typetraits,
  eth/common,
  results,
  ../core_db

type
  AccountLedger* = distinct CoreDxAccRef
  StorageLedger* = distinct CoreDxPhkRef
  SomeLedger* = AccountLedger | StorageLedger


proc rootHash*(t: SomeLedger): Hash256 =
  t.distinctBase.rootVid().hash().expect "SomeLedger/rootHash()"

proc rootVid*(t: SomeLedger): CoreDbVidRef =
  t.distinctBase.rootVid


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


proc init*(
    T: type StorageLedger;
    al: AccountLedger;
    account: CoreDbAccount;
    isPruning = true;
      ): T =
  al.distinctBase.parent.newMpt(account.storageVid, isPruning).toPhk.T

proc init*(T: type StorageLedger; db: CoreDbRef, isPruning = true): T =
  db.newMpt(CoreDbVidRef(nil), isPruning).toPhk.T

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

# End
