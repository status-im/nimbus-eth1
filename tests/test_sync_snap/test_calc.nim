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

import
  std/[random, sequtils],
  eth/common,
  stew/byteutils,
  unittest2,
  ../../nimbus/sync/[handlers, protocol],
  ../../nimbus/sync/snap/range_desc,
  ../../nimbus/sync/snap/worker/db/[hexary_desc, hexary_range],
  ./test_helpers

const
  accObjRlpMin = 70                   # min size of an encoded `Account()` obj
  accObjRlpMax = 110                  # max size of an encoded `Account()` obj
var
  accBlobs: array[accObjRlpMax - accObjRlpMin + 1, Blob]
  brNode = XNodeObj(kind: Branch)
  nodeBlob: Blob

# ------------------------------------------------------------------------------
# Private helpers for `test_calcAccountsListSizes()`
# ------------------------------------------------------------------------------

proc `==`(a,b: ChainId): bool {.borrow.}
  ## helper for ` test_calcBlockBodyTranscode()`

# ------------------

proc randAccSize(r: var Rand): int =
  ## Print random account size
  accObjRlpMin + r.rand(accBlobs.len - 1)

proc accBlob(n: int): Blob =
  let inx = n - accObjRlpMin
  if 0 <= inx and inx < accBlobs.len:
    accBlobs[inx]
  else:
    @[]

proc initAccBlobs() =
  if accBlobs[0].len == 0:
    let ffAccLen = Account(
      storageRoot: Hash256(data: high(UInt256).toBytesBE),
      codeHash:    Hash256(data: high(UInt256).toBytesBE),
      nonce:       high(uint64),
      balance:     high(UInt256)).encode.len

    check accObjRlpMin == Account().encode.len
    check accObjRlpMax == ffAccLen

    # Initialise
    for n in 0 ..< accBlobs.len:
      accBlobs[n] = 5.byte.repeat(accObjRlpMin + n)

    # Verify
    for n in 0 .. (accObjRlpMax + 2):
      if accObjRlpMin <= n and n <= accObjRlpMax:
        check n == accBlob(n).len
      else:
        check 0 == accBlob(n).len

proc accRndChain(r: var Rand; nItems: int): seq[RangeLeaf] =
  for n in 0 ..< nItems:
    result.add RangeLeaf(data: accBlob(r.randAccSize()))
    discard result[^1].key.init (n mod 256).byte.repeat(32)

proc accRndChain(seed: int; nItems: int): seq[RangeLeaf] =
  var prng = initRand(seed)
  prng.accRndChain(nItems)

# ------------------------------------------------------------------------------
# Private helpers for `test_calcProofsListSizes()`
# ------------------------------------------------------------------------------

proc initBranchNodeSample() =
  if nodeBlob.len == 0:
    for n in 0 .. 15:
      brNode.bLink[n] = high(NodeTag).to(Blob)
    nodeBlob = brNode.convertTo(Blob)

# ------------------------------------------------------------------------------
# Public test function
# ------------------------------------------------------------------------------

proc test_calcAccountsListSizes*() =
  ## Verify accounts size calculation for `hexaryRangeLeafsProof()`.
  initAccBlobs()

  let chain = 42.accRndChain(123)

  # Emulate `hexaryRangeLeafsProof()` size calculations
  var sizeAccu = 0
  for n in 0 ..< chain.len:
    let (pairLen,listLen) =
      chain[n].data.len.hexaryRangeRlpLeafListSize(sizeAccu)
    check listLen == chain[0 .. n].encode.len
    sizeAccu += pairLen


proc  test_calcProofsListSizes*() =
  ## RLP does not allow static check ..
  initBranchNodeSample()

  for n in [0, 1, 2, 126, 127]:
    let
      nodeSample = nodeBlob.to(SnapProof).repeat(n)
      nodeBlobsEncoded = nodeSample.proofEncode
      nodeBlobsDecoded = nodeBlobsEncoded.proofDecode
      nodeBlobsHex = nodeBlobsEncoded.toHex
      brNodesHex = brNode.repeat(n).convertTo(Blob).toHex
    #echo "+++ ", n, " ", nodeBlobsEncoded.rlpFromBytes.inspect
    #echo ">>> ", n, " ", nodeBlobsHex
    #echo "<<< ", n, " ", brNodesHex
    check nodeBlobsEncoded.len == n.hexaryRangeRlpNodesListSizeMax
    check nodeBlobsDecoded == nodeSample
    check nodeBlobsHex == brNodesHex


proc test_calcTrieNodeTranscode*() =
  ## RLP encode/decode a list of `SnapTriePaths` objects
  let
    raw = @[
      # Accounts
      SnapTriePaths(accPath: @[1.byte]),
      SnapTriePaths(accPath: @[2.byte]),
      SnapTriePaths(accPath: @[3.byte]),

      # Storage slots
      SnapTriePaths(
        accPath:   4.u256.NodeTag.to(Blob),
        slotPaths: @[@[4.byte,1.byte], @[4.byte,2.byte], @[4.byte,3.byte]]),
      SnapTriePaths(
        accPath:   5.u256.NodeTag.to(Blob),
        slotPaths: @[@[5.byte,4.byte], @[5.byte,5.byte], @[5.byte,6.byte]]),
      SnapTriePaths(
        accPath:   6.u256.NodeTag.to(Blob),
        slotPaths: @[@[6.byte,7.byte], @[6.byte,8.byte], @[6.byte,9.byte]]),

      # Accounts contd.
      SnapTriePaths(accPath: @[7.byte]),
      SnapTriePaths(accPath: @[8.byte]),
      SnapTriePaths(accPath: @[9.byte])]

    cured = @[
      @[@[1.byte]],
      @[@[2.byte]],
      @[@[3.byte]],

      @[4.u256.NodeTag.to(Blob),
        @[4.byte,1.byte], @[4.byte,2.byte], @[4.byte,3.byte]],
      @[5.u256.NodeTag.to(Blob),
        @[5.byte,4.byte], @[5.byte,5.byte], @[5.byte,6.byte]],
      @[6.u256.NodeTag.to(Blob),
        @[6.byte,7.byte], @[6.byte,8.byte], @[6.byte,9.byte]],

      @[@[7.byte]],
      @[@[8.byte]],
      @[@[9.byte]]]

  # cook it
  proc append(w: var RlpWriter; p: SnapTriePaths) = w.snapAppend p
  let cooked = rlp.encode raw
  check cooked == rlp.encode cured

  # reverse
  proc read(rlp: var Rlp; T: type SnapTriePaths): T = rlp.snapRead T
  check raw == rlp.decode(cooked, seq[SnapTriePaths])
  check cured == rlp.decode(cooked, seq[seq[Blob]])


proc test_calcBlockBodyTranscode*() =
  ## RLP encode/decode a list of `BlockBody` objects. Note that tere is/was a
  ## problem in `eth/common/eth_types_rlp.append()` for `BlockBody` encoding.
  let blkSeq = @[
    BlockBody(
      transactions: @[
        Transaction(nonce: 1)]),
    BlockBody(
      uncles: @[
        BlockHeader(nonce: [0x20u8,0,0,0,0,0,0,0])]),
    BlockBody(),
    BlockBody(
      transactions: @[
        Transaction(nonce: 3),
        Transaction(nonce: 4)])]

  let trBlkSeq = blkSeq.encode.decode(typeof blkSeq)

  check trBlkSeq.len == blkSeq.len
  for n in 0 ..< min(trBlkSeq.len, trBlkSeq.len):
    check (n, trBlkSeq[n]) == (n, blkSeq[n])

# ------------------------------------------------------------------------------
# End
# ------------------------------------------------------------------------------
