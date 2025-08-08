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
  eth/[common, rlp],
  results,
  ./[aristo_constants, aristo_desc]

# ------------------------------------------------------------------------------
# Public RLP transcoder mixins
# ------------------------------------------------------------------------------

proc toRlpBytes*(acc: AristoAccount, key: HashKey): seq[byte] =
  rlp.encode Account(
    nonce: acc.nonce,
    balance: acc.balance,
    storageRoot: key.to(Hash32),
    codeHash: acc.codeHash,
  )

proc to*(node: NodeRef, T: type array[2, seq[byte]]): T =
  ## Convert the argument pait `w` to a single or a double item list item of
  ## `<rlp-encoded-node>` type entries. Only in case of a combined extension
  ## and branch vertex argument, there will be a double item list result.
  ##
  case node.vtx.vType
  of Branches:
    # Do branch node
    var wr = initRlpWriter()
    wr.startList(17)
    for key in node.key:
      wr.append key
    wr.append EmptyBlob
    let brData = wr.finish()

    if node.vtx.vType == ExtBranch:
      # Prefix branch by embedded extension node
      let brHash = brData.digestTo(HashKey)

      var wrx = initRlpWriter()
      wrx.startList(2)
      wrx.append node.vtx.pfx.toHexPrefix(isleaf = false).data()
      wrx.append brHash

      [wrx.finish(), brData]
    else:
      # Do for pure branch node
      [brData, @[]]
  of AccLeaf:
    let vtx = AccLeafRef(node.vtx)
    var wr = initRlpWriter()
    wr.startList(2)
    wr.append vtx.pfx.toHexPrefix(isleaf = true).data()
    wr.append vtx.account.toRlpBytes(node.key[0])

    [wr.finish(), @[]]
  of StoLeaf:
    let vtx = StoLeafRef(node.vtx)
    var wr = initRlpWriter()
    wr.startList(2)
    wr.append vtx.pfx.toHexPrefix(isleaf = true).data()
    wr.append rlp.encode vtx.stoData

    [wr.finish(), @[]]

proc digestTo*(node: NodeRef; T: type HashKey): T =
  ## Convert the argument `node` to the corresponding Merkle hash key. Note
  ## that a `Dummy` node is encoded as as a `Leaf`.
  ##
  var wr = initRlpWriter()
  case node.vtx.vType
  of Branches:
    # Do branch node
    wr.startList(17)
    for key in node.key:
      wr.append key
    wr.append EmptyBlob

    # Do for embedded extension node
    if 0 < node.vtx.pfx.len:
      let brHash = wr.finish().digestTo(HashKey)
      wr = initRlpWriter()
      wr.startList(2)
      wr.append node.vtx.pfx.toHexPrefix(isleaf = false).data()
      wr.append brHash
  of AccLeaf:
    let vtx = AccLeafRef(node.vtx)

    wr.startList(2)
    wr.append node.vtx.pfx.toHexPrefix(isleaf = true).data()
    wr.append vtx.account.toRlpBytes(node.key[0])
  of StoLeaf:
    let vtx = StoLeafRef(node.vtx)
    var wr = initRlpWriter()
    wr.startList(2)
    wr.append vtx.pfx.toHexPrefix(isleaf = true).data()
    wr.append rlp.encode vtx.stoData

  wr.finish().digestTo(HashKey)

# ------------------------------------------------------------------------------
# End
# ------------------------------------------------------------------------------
