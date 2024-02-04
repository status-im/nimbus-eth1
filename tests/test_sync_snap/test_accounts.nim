# Nimbus
# Copyright (c) 2022-2023 Status Research & Development GmbH
# Licensed under either of
#  * Apache License, version 2.0, ([LICENSE-APACHE](LICENSE-APACHE) or
#    http://www.apache.org/licenses/LICENSE-2.0)
#  * MIT license ([LICENSE-MIT](LICENSE-MIT) or
#    http://opensource.org/licenses/MIT)
# at your option. This file may not be copied, modified, or
# distributed except according to those terms.

## Snap sync components tester and TDD environment
##
## This module provides test bodies for storing chain chain data directly
## rather than derive them by executing the EVM. Here, only accounts are
## considered.
##
## The `snap/1` protocol allows to fetch data for a certain account range. The
## following boundary conditions apply to the received data:
##
## * `State root`: All data are relaive to the same state root.
##
## * `Accounts`: There is an accounts interval sorted in strictly increasing
##   order. The accounts are required consecutive, i.e. without holes in
##   between although this cannot be verified immediately.
##
## * `Lower bound`: There is a start value which might be lower than the first
##   account hash. There must be no other account between this start value and
##   the first account (not verifyable yet.) For all practicat purposes, this
##   value is mostly ignored but carried through.
##
## * `Proof`: There is a list of hexary nodes which allow to build a partial
##   Patricia-Merkle trie starting at the state root with all the account
##   leaves. There are enough nodes that show that there is no account before
##   the least account (which is currently ignored.)
##
## There are test data samples on the sub-directory `test_sync_snap`. These
## are complete replies for some (admittedly snap) test requests from a `kiln#`
## session.
##
## There are three tests:
##
## 1. Run the `test_accountsImport()` function which is the all-in-one
##    production function processoing the data described above. The test
##    applies it sequentially to all argument data sets.
##
## 2. With `test_accountsMergeProofs()` individual items are tested which are
##    hidden in test 1. while merging the sample data.
##    * Load/accumulate `proofs` data from several samples
##    * Load/accumulate accounts (needs some unique sorting)
##    * Build/complete hexary trie for accounts
##    * Save/bulk-store hexary trie on disk. If rocksdb is available, data
##      are bulk stored via sst.
##
## 3. The function `test_accountsRevisitStoredItems()` traverses trie nodes
##    stored earlier. The accounts from test 2 are re-visted using the account
##    hash as access path.
##

import
  std/algorithm,
  eth/[common, p2p],
  unittest2,
  ../../nimbus/sync/protocol,
  ../../nimbus/sync/snap/range_desc,
  ../../nimbus/sync/snap/worker/db/[
    hexary_debug, hexary_desc, hexary_error,
    snapdb_accounts, snapdb_debug, snapdb_desc],
  ../replay/[pp, undump_accounts],
  ./test_helpers

# ------------------------------------------------------------------------------
# Private helpers
# ------------------------------------------------------------------------------

proc flatten(list: openArray[seq[SnapProof]]): seq[SnapProof] =
  for w in list:
    result.add w

# ------------------------------------------------------------------------------
# Public test function
# ------------------------------------------------------------------------------

proc test_accountsImport*(
    inList: seq[UndumpAccounts];
    desc: SnapDbAccountsRef;
    persistent: bool;
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
  let
    getFn = desc.getAccountFn
    baseTag = inList.mapIt(it.base).sortMerge
    packed = PackedAccountRange(
      accounts: inList.mapIt(it.data.accounts).sortMerge,
      proof:    inList.mapIt(it.data.proof).flatten)
    nAccounts = packed.accounts.len
  # Merging intervals will produce gaps, so the result is expected OK but
  # different from `.isImportOk`
  check desc.importAccounts(baseTag, packed, true).isOk

  # for debugging, make sure that state root ~ "$0"
  desc.hexaDb.assignPrettyKeys(desc.root)

  # Update list of accounts. There might be additional accounts in the set
  # of proof nodes, typically before the `lowerBound` of each block. As
  # there is a list of account ranges (that were merged for testing), one
  # need to check for additional records only on either end of a range.
  var keySet = packed.accounts.mapIt(it.accKey).toHashSet
  for w in inList:
    var key = desc.prevAccountsChainDbKey(w.data.accounts[0].accKey, getFn)
    while key.isOk and key.value notin keySet:
      keySet.incl key.value
      let newKey = desc.prevAccountsChainDbKey(key.value, getFn)
      check newKey != key
      key = newKey
    key = desc.nextAccountsChainDbKey(w.data.accounts[^1].accKey, getFn)
    while key.isOk and key.value notin keySet:
      keySet.incl key.value
      let newKey = desc.nextAccountsChainDbKey(key.value, getFn)
      check newKey != key
      key = newKey
  accKeys = toSeq(keySet).mapIt(it.to(NodeTag)).sorted(cmp)
                         .mapIt(it.to(NodeKey))
  # Some database samples have a few more account keys which come in by the
  # proof nodes.
  check nAccounts <= accKeys.len

  # Verify against table importer
  let
    xDb = HexaryTreeDbRef.init() # Can dump database with `.pp(xDb)`
    rc = xDb.fromPersistent(desc.root, getFn, accKeys.len + 100)
  check rc == Result[int,HexaryError].ok(accKeys.len)


proc test_accountsRevisitStoredItems*(
    accKeys: seq[NodeKey];
    desc: SnapDbAccountsRef;
    noisy = false;
      ) =
  ## Revisit stored items on ChainDBRef
  let
    getFn = desc.getAccountFn
  var
    nextAccount = accKeys[0]
    prevAccount: NodeKey
    count = 0
  for accKey in accKeys:
    count.inc
    let
      pfx = $count & "#"
      byChainDB = desc.getAccountsData(accKey, persistent=true)
      byNextKey = desc.nextAccountsChainDbKey(accKey, getFn)
      byPrevKey = desc.prevAccountsChainDbKey(accKey, getFn)
    if byChainDB.isErr:
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
