# Nimbus - Types, data structures and shared utilities used in network sync
#
# Copyright (c) 2018-2021 Status Research & Development GmbH
# Licensed under either of
#  * Apache License, version 2.0, ([LICENSE-APACHE](LICENSE-APACHE) or
#    http://www.apache.org/licenses/LICENSE-2.0)
#  * MIT license ([LICENSE-MIT](LICENSE-MIT) or
#    http://opensource.org/licenses/MIT)
# at your option. This file may not be copied, modified, or
# distributed except according to those terms.

## Snap sync components tester and TDD environment

import
  std/[algorithm, sequtils, strformat, strutils, tables],
  eth/[common, p2p, trie/db],
  unittest2,
  ../../nimbus/db/select_backend,
  ../../nimbus/sync/snap/range_desc,
  ../../nimbus/sync/snap/worker/db/[snapdb_accounts, snapdb_desc],
  ../replay/[pp, undump_accounts],
  ./test_helpers

# ------------------------------------------------------------------------------
# Private helpers
# ------------------------------------------------------------------------------

proc flatten(list: openArray[seq[Blob]]): seq[Blob] =
  for w in list:
    result.add w

# ------------------------------------------------------------------------------
# Public test function
# ------------------------------------------------------------------------------

proc test_accountsImport*(
    inList: seq[UndumpAccounts];
    desc: SnapDbAccountsRef;
    persistent: bool
      ) =
  ## Import accounts
  for n,w in inList:
    check desc.importAccounts(w.base, w.data, persistent).isImportOk


proc test_accountsMergeProofs*(
    inList: seq[UndumpAccounts];
    desc: SnapDbAccountsRef;
    accKeys: var seq[NodeKey];
      ) =
  ## Merge account proofs
  # Load/accumulate data from several samples (needs some particular sort)
  let baseTag = inList.mapIt(it.base).sortMerge
  let packed = PackedAccountRange(
    accounts: inList.mapIt(it.data.accounts).sortMerge,
    proof:    inList.mapIt(it.data.proof).flatten)
  # Merging intervals will produce gaps, so the result is expected OK but
  # different from `.isImportOk`
  check desc.importAccounts(baseTag, packed, true).isOk

  # check desc.merge(lowerBound, accounts) == OkHexDb
  desc.assignPrettyKeys() # for debugging, make sure that state root ~ "$0"

  # Update list of accounts. There might be additional accounts in the set
  # of proof nodes, typically before the `lowerBound` of each block. As
  # there is a list of account ranges (that were merged for testing), one
  # need to check for additional records only on either end of a range.
  var keySet = packed.accounts.mapIt(it.accKey).toHashSet
  for w in inList:
    var key = desc.prevAccountsChainDbKey(w.data.accounts[0].accKey)
    while key.isOk and key.value notin keySet:
      keySet.incl key.value
      let newKey = desc.prevAccountsChainDbKey(key.value)
      check newKey != key
      key = newKey
    key = desc.nextAccountsChainDbKey(w.data.accounts[^1].accKey)
    while key.isOk and key.value notin keySet:
      keySet.incl key.value
      let newKey = desc.nextAccountsChainDbKey(key.value)
      check newKey != key
      key = newKey
  accKeys = toSeq(keySet).mapIt(it.to(NodeTag)).sorted(cmp)
                         .mapIt(it.to(NodeKey))
  check packed.accounts.len <= accKeys.len


proc test_accountsRevisitStoredItems*(
    accKeys: seq[NodeKey];
    desc: SnapDbAccountsRef;
    noisy = false;
      ) =
  ## Revisit stored items on ChainDBRef
  var
    nextAccount = accKeys[0]
    prevAccount: NodeKey
    count = 0
  for accKey in accKeys:
    count.inc
    let
      pfx = $count & "#"
      byChainDB = desc.getAccountsChainDb(accKey)
      byNextKey = desc.nextAccountsChainDbKey(accKey)
      byPrevKey = desc.prevAccountsChainDbKey(accKey)
    noisy.say "*** find",
      "<", count, "> byChainDb=", byChainDB.pp
    check byChainDB.isOk

    # Check `next` traversal funcionality. If `byNextKey.isOk` fails, the
    # `nextAccount` value is still the old one and will be different from
    # the account in the next for-loop cycle (if any.)
    check pfx & accKey.pp(false) == pfx & nextAccount.pp(false)
    if byNextKey.isOk:
      nextAccount = byNextKey.get(otherwise = NodeKey.default)

    # Check `prev` traversal funcionality
    if prevAccount != NodeKey.default:
      check byPrevKey.isOk
      if byPrevKey.isOk:
        check pfx & byPrevKey.value.pp(false) == pfx & prevAccount.pp(false)
    prevAccount = accKey

# ------------------------------------------------------------------------------
# End
# ------------------------------------------------------------------------------
