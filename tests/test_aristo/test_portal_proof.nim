# Nimbus
# Copyright (c) 2023-2024 Status Research & Development GmbH
# Licensed under either of
#  * Apache License, version 2.0, ([LICENSE-APACHE](LICENSE-APACHE) or
#    http://www.apache.org/licenses/LICENSE-2.0)
#  * MIT license ([LICENSE-MIT](LICENSE-MIT) or
#    http://opensource.org/licenses/MIT)
# at your option. This file may not be copied, modified, or
# distributed except according to those terms.

{.used.}

import
  std/[json, os, sets, strutils, tables],
  eth/common,
  stew/byteutils,
  results,
  unittest2,
  ../test_helpers,
  ../../nimbus/db/aristo,
  ../../nimbus/db/aristo/[aristo_desc, aristo_get, aristo_hike, aristo_layers,
                          aristo_part],
  ../../nimbus/db/aristo/aristo_part/part_debug

type
  ProofData = ref object
    chain: seq[Blob]
    error: AristoError
    hike: Hike

# ------------------------------------------------------------------------------
# Private helper
# ------------------------------------------------------------------------------

proc createPartDb(ps: PartStateRef; data: seq[Blob]; info: static[string]) =
  # Set up production MPT
  block:
    let rc = ps.partPut(data, AutomaticPayload)
    if rc.isErr: raiseAssert info & ": partPut => " & $rc.error

  # Save keys to database
  for (rvid,key) in ps.vkPairs:
    ps.db.layersPutKey(rvid, key)

  # Make sure all is OK
  block:
    let rc = ps.check()
    if rc.isErr: raiseAssert info & ": check => " & $rc.error


proc preLoadAristoDb(jKvp: JsonNode): PartStateRef =
  const info = "preLoadAristoDb"
  let ps = PartStateRef.init AristoDbRef.init()

  # Collect rlp-encodede node blobs
  var proof: seq[Blob]
  for (k,v) in jKvp.pairs:
    let
      key = hexToSeqByte(k)
      val = hexToSeqByte(v.getStr())
    if key.len == 32:
      doAssert key == val.keccakHash.data
      if val != @[0x80u8]: # Exclude empty item
        proof.add val

  ps.createPartDb(proof, info)
  ps


proc collectAddresses(node: JsonNode, collect: var HashSet[EthAddress]) =
  case node.kind:
    of JObject:
      for k,v in node.pairs:
        if k == "address" and v.kind == JString:
          collect.incl EthAddress.fromHex v.getStr
        else:
          v.collectAddresses collect
    of JArray:
      for v in node.items:
        v.collectAddresses collect
    else:
      discard


proc payloadAsBlob(pyl: LeafPayload; ps: PartStateRef): Blob =
  ## Modified function `aristo_serialise.serialise()`.
  ##
  const info = "payloadAsBlob"
  case pyl.pType:
  of RawData:
    pyl.rawBlob
  of AccountData:
    let
      vid = pyl.stoID
      key = block:
        if vid.isValid:
          let rc = ps.db.getKeyRc (VertexID(1),vid)
          if rc.isErr:
            raiseAssert info & ": getKey => " & $rc.error
          rc.value[0]
        else:
          VOID_HASH_KEY

    rlp.encode Account(
      nonce:       pyl.account.nonce,
      balance:     pyl.account.balance,
      storageRoot: key.to(Hash256),
      codeHash:    pyl.account.codeHash)
  of StoData:
    rlp.encode pyl.stoData


func asExtension(b: Blob; path: Hash256): Blob =
  var node = rlpFromBytes b
  if node.listLen == 17:
    let nibble = NibblesBuf.fromBytes(path.data)[0]
    var wr = initRlpWriter()

    wr.startList(2)
    wr.append NibblesBuf.fromBytes(@[nibble]).slice(1).toHexPrefix(isleaf=false)
    wr.append node.listElem(nibble.int).toBytes
    wr.finish()

  else:
    b

# ------------------------------------------------------------------------------
# Private test functions
# ------------------------------------------------------------------------------

proc testCreatePortalProof(node: JsonNode, testStatusIMPL: var TestStatus) =
  const info = "testCreateProofTwig"

  # Create partial database
  let ps = node["state"].preLoadAristoDb()

  # Collect addresses from json structure
  var addresses: HashSet[EthAddress]
  node.collectAddresses addresses

  # Convert addresses to valid paths (not all addresses might work)
  var sample: Table[Hash256,ProofData]
  for a in addresses:
    let
      path = a.keccakHash
      rc = path.hikeUp(VertexID(1), ps.db)
    sample[path] = ProofData(
      error: (if rc.isErr: rc.error[1] else: AristoError(0)),
      hike: rc.to(Hike)) # keep `hike` for potential debugging

  # Verify that there is somehing to do, at all
  check 0 < sample.values.toSeq.filterIt(it.error == AristoError 0).len

  # Create proof chains
  for (path,proof) in sample.pairs:
    let rc = ps.db.partAccountTwig path
    check rc.isOk == (proof.error == AristoError 0)
    if rc.isOk:
      proof.chain = rc.value

  # Verify proof chains
  for (path,proof) in sample.pairs:
    if proof.error == AristoError 0:
      let
        rVid = proof.hike.root
        pyl = proof.hike.legs[^1].wp.vtx.lData.payloadAsBlob(ps)

      block:
        # Use these root and chain
        let chain = proof.chain

        # Create another partial database from tree
        let pq = PartStateRef.init AristoDbRef.init()
        pq.createPartDb(chain, info)

        # Create the same proof again which must result into the same as before
        block:
          let rc = pq.db.partAccountTwig path
          check rc.isOk
          if rc.isOk:
            check rc.value == proof.chain

      # Extension nodes are rare, so there is one created, inserted and the
      # previous test repeated.
      block:
        let
          ext = proof.chain[0].asExtension(path)
          tail = @(proof.chain.toOpenArray(1,proof.chain.len-1))
          chain = @[ext] & tail

        # Create a third partial database from modified proof
        let pq = PartStateRef.init AristoDbRef.init()
        pq.createPartDb(chain, info)

        # Re-create proof again
        block:
          let rc = pq.db.partAccountTwig path
          check rc.isOk
          if rc.isOk:
            check rc.value == chain

# ------------------------------------------------------------------------------
# Test
# ------------------------------------------------------------------------------

suite "Encoding & verification of portal proof twigs for Aristo DB":
  # Piggyback on tracer test suite environment
  jsonTest("TracerTests", testCreatePortalProof)

# ------------------------------------------------------------------------------
# End
# ------------------------------------------------------------------------------
