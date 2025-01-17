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
  "."/[aristo_constants, aristo_desc, aristo_compute]

type
  ResolveVidFn = proc(
      vid: VertexID;
        ): Result[HashKey,AristoError]
        {.gcsafe, raises: [].}
    ## Resolve storage root vertex ID

# ------------------------------------------------------------------------------
# Private helper
# ------------------------------------------------------------------------------

proc serialise(
    pyl: LeafPayload;
    getKey: ResolveVidFn;
      ): Result[seq[byte],(VertexID,AristoError)] =
  ## Encode the data payload of the argument `pyl` as RLP `seq[byte]` if it is
  ## of account type, otherwise pass the data as is.
  ##
  case pyl.pType:
  of AccountData:
    let key = block:
      if pyl.stoID.isValid:
        pyl.stoID.vid.getKey.valueOr:
          let w = (pyl.stoID.vid, error)
          return err(w)
      else:
        VOID_HASH_KEY

    ok rlp.encode Account(
      nonce:       pyl.account.nonce,
      balance:     pyl.account.balance,
      storageRoot: key.to(Hash32),
      codeHash:    pyl.account.codeHash)
  of StoData:
    ok rlp.encode pyl.stoData

# ------------------------------------------------------------------------------
# Public RLP transcoder mixins
# ------------------------------------------------------------------------------

proc to*(node: NodeRef; T: type seq[seq[byte]]): T =
  ## Convert the argument pait `w` to a single or a double item list item of
  ## `<rlp-encoded-node>` type entries. Only in case of a combined extension
  ## and branch vertex argument, there will be a double item list result.
  ##
  case node.vtx.vType:
  of Branch:
    # Do branch node
    var wr = initRlpWriter()
    wr.startList(17)
    for n in 0..15:
      wr.append node.key[n]
    wr.append EmptyBlob
    let brData = wr.finish()

    if 0 < node.vtx.pfx.len:
      # Prefix branch by embedded extension node
      let brHash = brData.digestTo(HashKey)

      var wrx = initRlpWriter()
      wrx.startList(2)
      wrx.append node.vtx.pfx.toHexPrefix(isleaf = false).data()
      wrx.append brHash

      result.add wrx.finish()
      result.add brData
    else:
      # Do for pure branch node
      result.add brData

  of Leaf:
    proc getKey0(
        vid: VertexID;
          ): Result[HashKey,AristoError]
          {.gcsafe, raises: [].} =
      ok(node.key[0]) # always succeeds

    var wr = initRlpWriter()
    wr.startList(2)
    wr.append node.vtx.pfx.toHexPrefix(isleaf = true).data()
    wr.append node.vtx.lData.serialise(getKey0).value

    result.add (wr.finish())

proc digestTo*(node: NodeRef; T: type HashKey): T =
  ## Convert the argument `node` to the corresponding Merkle hash key. Note
  ## that a `Dummy` node is encoded as as a `Leaf`.
  ##
  var wr = initRlpWriter()
  case node.vtx.vType:
  of Branch:
    # Do branch node
    wr.startList(17)
    for n in 0..15:
      wr.append node.key[n]
    wr.append EmptyBlob

    # Do for embedded extension node
    if 0 < node.vtx.pfx.len:
      let brHash = wr.finish().digestTo(HashKey)
      wr = initRlpWriter()
      wr.startList(2)
      wr.append node.vtx.pfx.toHexPrefix(isleaf = false).data()
      wr.append brHash

  of Leaf:
    proc getKey0(
        vid: VertexID;
          ): Result[HashKey,AristoError]
          {.gcsafe, raises: [].} =
      ok(node.key[0]) # always succeeds

    wr.startList(2)
    wr.append node.vtx.pfx.toHexPrefix(isleaf = true).data()
    wr.append node.vtx.lData.serialise(getKey0).value

  wr.finish().digestTo(HashKey)

proc serialise*(
    db: AristoTxRef;
    root: VertexID;
    pyl: LeafPayload;
      ): Result[seq[byte],(VertexID,AristoError)] =
  ## Encode the data payload of the argument `pyl` as RLP `seq[byte]` if it is
  ## of account type, otherwise pass the data as is.
  ##
  proc getKey(vid: VertexID): Result[HashKey,AristoError] =
    ok (?db.computeKey((root, vid)))

  pyl.serialise getKey

# ------------------------------------------------------------------------------
# End
# ------------------------------------------------------------------------------
