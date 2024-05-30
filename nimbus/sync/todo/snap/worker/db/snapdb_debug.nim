# nimbus-eth1
# Copyright (c) 2021-2024 Status Research & Development GmbH
# Licensed under either of
#  * Apache License, version 2.0, ([LICENSE-APACHE](LICENSE-APACHE) or
#    http://www.apache.org/licenses/LICENSE-2.0)
#  * MIT license ([LICENSE-MIT](LICENSE-MIT) or
#    http://opensource.org/licenses/MIT)
# at your option. This file may not be copied, modified, or distributed
# except according to those terms.

{.push raises: [].}

import
  std/[algorithm, sequtils, tables],
  eth/[common, trie/nibbles],
  results,
  ../../range_desc,
  "."/[hexary_debug, hexary_desc, hexary_error, hexary_paths, snapdb_desc]

# ------------------------------------------------------------------------------
# Private debugging helpers
# ------------------------------------------------------------------------------

template noPpError(info: static[string]; code: untyped) =
  try:
    code
  except ValueError as e:
    raiseAssert "Inconveivable (" & info & "): " & e.msg
  except KeyError as e:
    raiseAssert "Not possible (" & info & "): " & e.msg
  except CatchableError as e:
    raiseAssert "Ooops (" & info & ") " & $e.name & ": " & e.msg

# ------------------------------------------------------------------------------
# Private helpers
# ------------------------------------------------------------------------------

proc convertTo(data: openArray[byte]; T: type Hash256): T =
  discard result.data.NodeKey.init(data) # size error => zero

template noKeyError(info: static[string]; code: untyped) =
  try:
    code
  except KeyError as e:
    raiseAssert "Not possible (" & info & "): " & e.msg

template noExceptionOops(info: static[string]; code: untyped) =
  try:
    code
  except KeyError as e:
    raiseAssert "Not possible -- " & info & ": " & e.msg
  except RlpError:
    return err(RlpEncoding)
  except CatchableError:
    return err(AccountNotFound)

# ------------------------------------------------------------------------------
# Public functions, pretty printing
# ------------------------------------------------------------------------------

proc pp*(a: RepairKey; ps: SnapDbBaseRef): string =
  if not ps.isNil:
    let toKey = ps.hexaDb.keyPp
    if not toKey.isNil:
      try:
        return a.toKey
      except CatchableError:
        discard
  $a.ByteArray33

proc pp*(a: NodeKey; ps: SnapDbBaseRef): string =
  if not ps.isNil:
    let toKey = ps.hexaDb.keyPp
    if not toKey.isNil:
      try:
        return a.to(RepairKey).toKey
      except CatchableError:
        discard
  $a.ByteArray32

proc pp*(a: NodeTag; ps: SnapDbBaseRef): string =
  a.to(NodeKey).pp(ps)

# ------------------------------------------------------------------------------
# Public constructor
# ------------------------------------------------------------------------------

proc init*(
    T: type HexaryTreeDbRef;
      ): T =
  ## Constructor variant. It provides a `HexaryTreeDbRef()` with a key cache
  ## attached for pretty printing. So this one is mainly for debugging.
  HexaryTreeDbRef.init(SnapDbRef())

# ------------------------------------------------------------------------------
# Public functions
# ------------------------------------------------------------------------------

proc sortMerge*(base: openArray[NodeTag]): NodeTag =
  ## Helper for merging several `(NodeTag,seq[PackedAccount])` data sets
  ## so that there are no overlap which would be rejected by `merge()`.
  ##
  ## This function selects a `NodeTag` from a list.
  result = high(NodeTag)
  for w in base:
    if w < result:
      result = w

proc sortMerge*(acc: openArray[seq[PackedAccount]]): seq[PackedAccount] =
  ## Helper for merging several `(NodeTag,seq[PackedAccount])` data sets
  ## so that there are no overlap which would be rejected by `merge()`.
  ##
  ## This function flattens and sorts the argument account lists.
  noKeyError("sortMergeAccounts"):
    var accounts: Table[NodeTag,PackedAccount]
    for accList in acc:
      for item in accList:
        accounts[item.accKey.to(NodeTag)] = item
    result = toSeq(accounts.keys).sorted(cmp).mapIt(accounts[it])

proc nextAccountsChainDbKey*(
    ps: SnapDbBaseRef;
    accKey: NodeKey;
    getFn: HexaryGetFn;
      ): Result[NodeKey,HexaryError] =
  ## Fetch the account path on the `CoreDbRef`, the one next to the
  ## argument account key.
  noExceptionOops("getChainDbAccount()"):
    let path = accKey
               .hexaryPath(ps.root, getFn) # ps.getAccountFn)
               .next(getFn)                # ps.getAccountFn)
               .getNibbles
    if 64 == path.len:
      return ok(path.getBytes.convertTo(Hash256).to(NodeKey))

  err(AccountNotFound)

proc prevAccountsChainDbKey*(
    ps: SnapDbBaseRef;
    accKey: NodeKey;
    getFn: HexaryGetFn;
      ): Result[NodeKey,HexaryError] =
  ## Fetch the account path on the `CoreDbRef`, the one before to the
  ## argument account.
  noExceptionOops("getChainDbAccount()"):
    let path = accKey
               .hexaryPath(ps.root, getFn) # ps.getAccountFn)
               .prev(getFn)                # ps.getAccountFn)
               .getNibbles
    if 64 == path.len:
      return ok(path.getBytes.convertTo(Hash256).to(NodeKey))

  err(AccountNotFound)

# ------------------------------------------------------------------------------
# More debugging (and playing with the hexary database)
# ------------------------------------------------------------------------------

proc assignPrettyKeys*(xDb: HexaryTreeDbRef; root: NodeKey) =
  ## Prepare for pretty pringing/debugging. Run early enough this function
  ## sets the root key to `"$"`, for instance.
  if not xDb.keyPp.isNil:
    noPpError("validate(1)"):
      # Make keys assigned in pretty order for printing
      let rootKey = root.to(RepairKey)
      discard xDb.keyPp rootKey
      var keysList = toSeq(xDb.tab.keys)
      if xDb.tab.hasKey(rootKey):
        keysList = @[rootKey] & keysList
      for key in keysList:
        let node = xDb.tab[key]
        discard xDb.keyPp key
        case node.kind:
        of Branch: (for w in node.bLink: discard xDb.keyPp w)
        of Extension: discard xDb.keyPp node.eLink
        of Leaf: discard

# ------------------------------------------------------------------------------
# End
# ------------------------------------------------------------------------------
