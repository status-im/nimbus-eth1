# nimbus-eth1
# Copyright (c) 2023-2025 Status Research & Development GmbH
# Licensed under either of
#  * Apache License, version 2.0, ([LICENSE-APACHE](LICENSE-APACHE) or
#    http://www.apache.org/licenses/LICENSE-2.0)
#  * MIT license ([LICENSE-MIT](LICENSE-MIT) or
#    http://opensource.org/licenses/MIT)
# at your option. This file may not be copied, modified, or distributed
# except according to those terms.

{.push raises: [].}

import
  eth/common/[accounts_rlp, base_rlp, hashes_rlp],
  results,
  ./[aristo_constants, aristo_desc]

export aristo_constants, accounts_rlp

# ------------------------------------------------------------------------------
# RLP encoding constants
# ------------------------------------------------------------------------------

const
  MAX_RLP_SIZE_ACCOUNT_LEAF* = 111
  MAX_RLP_SIZE_STORAGE_LEAF* = 34
  MAX_RLP_SIZE_ACCOUNT_LEAF_NODE* = 149
  MAX_RLP_SIZE_STORAGE_LEAF_NODE* = 71
  MAX_RLP_SIZE_BRANCH_NODE* = 533
  MAX_RLP_SIZE_EXTENSION_NODE* = 69

# ------------------------------------------------------------------------------
# RLP encoding templates for MPT nodes
# ------------------------------------------------------------------------------

template rlpEncodeAccLeaf*(
    pfx: NibblesBuf, account: AristoAccount, storageKey: HashKey
): openArray[byte] =
  var accLeafW = RlpArrayBufWriter[MAX_RLP_SIZE_ACCOUNT_LEAF_NODE, 1]()
  accLeafW.startList(2)
  accLeafW.append(pfx.toHexPrefix(isLeaf = true).data())
  block:
    var accW = RlpArrayBufWriter[MAX_RLP_SIZE_ACCOUNT_LEAF, 1]()
    accW.append(Account(
      nonce: account.nonce,
      balance: account.balance,
      storageRoot: storageKey.to(Hash32),
      codeHash: account.codeHash))
    accLeafW.append(accW.finish(asOpenArray = true))
  accLeafW.finish(asOpenArray = true)

template rlpEncodeStoLeaf*(
    pfx: NibblesBuf, stoData: UInt256
): openArray[byte] =
  var stoLeafW = RlpArrayBufWriter[MAX_RLP_SIZE_STORAGE_LEAF_NODE, 1]()
  stoLeafW.startList(2)
  stoLeafW.append(pfx.toHexPrefix(isLeaf = true).data())
  block:
    var stoW = RlpArrayBufWriter[MAX_RLP_SIZE_STORAGE_LEAF, 1]()
    stoW.append(stoData)
    stoLeafW.append(stoW.finish(asOpenArray = true))
  stoLeafW.finish(asOpenArray = true)

template rlpEncodeBranch*(vtx: VertexRef, subKeyForN: untyped): openArray[byte] =
  var branchW = RlpArrayBufWriter[MAX_RLP_SIZE_BRANCH_NODE, 1]()
  branchW.startList(17)
  for (n {.inject.}, subvid {.inject.}) in vtx.allPairs():
    branchW.append(subKeyForN)
  branchW.append EmptyBlob
  branchW.finish(asOpenArray = true)

template rlpEncodeExt*(
    pfx: NibblesBuf, branchKey: HashKey
): openArray[byte] =
  var extW = RlpArrayBufWriter[MAX_RLP_SIZE_EXTENSION_NODE, 1]()
  extW.startList(2)
  extW.append(pfx.toHexPrefix(isLeaf = false).data())
  extW.append(branchKey)
  extW.finish(asOpenArray = true)

# ------------------------------------------------------------------------------
# Public RLP transcoder mixins
# ------------------------------------------------------------------------------

proc to*(node: NodeRef, T: type array[2, seq[byte]]): T =
  ## Convert the argument pait `w` to a single or a double item list item of
  ## `<rlp-encoded-node>` type entries. Only in case of a combined extension
  ## and branch vertex argument, there will be a double item list result.
  ##
  case node.vtx.vType
  of Branches:
    let brData = @(rlpEncodeBranch(node.vtx, node.key[n]))
    if node.vtx.vType == ExtBranch:
      let brHash = brData.digestTo(HashKey)
      [@(rlpEncodeExt(ExtBranchRef(node.vtx).pfx, brHash)), brData]
    else:
      [brData, @[]]
  of AccLeaf:
    let vtx = AccLeafRef(node.vtx)
    [@(rlpEncodeAccLeaf(vtx.pfx, vtx.account, node.key[0])), @[]]
  of StoLeaf:
    let vtx = StoLeafRef(node.vtx)
    [@(rlpEncodeStoLeaf(vtx.pfx, vtx.stoData)), @[]]

proc digestTo*(node: NodeRef; T: type HashKey): T =
  ## Convert the argument `node` to the corresponding Merkle hash key. Note
  ## that a `Dummy` node is encoded as as a `Leaf`.
  ##
  case node.vtx.vType
  of Branches:
    let brKey = rlpEncodeBranch(node.vtx, node.key[n]).digestTo(HashKey)
    if node.vtx.vType == ExtBranch:
      rlpEncodeExt(ExtBranchRef(node.vtx).pfx, brKey).digestTo(HashKey)
    else:
      brKey
  of AccLeaf:
    let vtx = AccLeafRef(node.vtx)
    rlpEncodeAccLeaf(vtx.pfx, vtx.account, node.key[0]).digestTo(HashKey)
  of StoLeaf:
    let vtx = StoLeafRef(node.vtx)
    rlpEncodeStoLeaf(vtx.pfx, vtx.stoData).digestTo(HashKey)

# ------------------------------------------------------------------------------
# End
# ------------------------------------------------------------------------------
