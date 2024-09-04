# Nimbus
# Copyright (c) 2023-2024 Status Research & Development GmbH
# Licensed and distributed under either of
#   * MIT license (license terms in the root directory or at
#     https://opensource.org/licenses/MIT).
#   * Apache v2 license (license terms in the root directory or at
#     https://www.apache.org/licenses/LICENSE-2.0).
# at your option. This file may not be copied, modified, or distributed
# except according to those terms.

import
  eth/rlp,
  eth/common/eth_types_rlp,
  ./skeleton_desc,
  ./skeleton_utils,
  ../../db/storage_types,
  ../../utils/utils,
  ../../core/chain

export
  eth_types_rlp.blockHash

{.push gcsafe, raises: [].}

logScope:
  topics = "skeleton"

# ------------------------------------------------------------------------------
# Private helpers
# ------------------------------------------------------------------------------

template get(sk: SkeletonRef, key: untyped): untyped =
  sk.db.ctx.getKvt().get(key.toOpenArray).valueOr: EmptyBlob

template put(sk: SkeletonRef, key, val: untyped): untyped =
  let rc = sk.db.ctx.getKvt().put(key.toOpenArray, val)
  if rc.isErr:
    raiseAssert "put() failed: " & $$rc.error

template del(sk: SkeletonRef, key: untyped): untyped =
  discard sk.db.ctx.getKvt().del(key.toOpenArray)

proc append(w: var RlpWriter, s: Segment) =
  w.startList(3)
  w.append(s.head)
  w.append(s.tail)
  w.append(s.next)

proc append(w: var RlpWriter, p: Progress) =
  w.startList(3)
  w.append(p.segments)
  w.append(p.linked)
  w.append(p.canonicalHeadReset)

proc readImpl(rlp: var Rlp, T: type Segment): Segment {.raises: [RlpError].} =
  rlp.tryEnterList()
  Segment(
    head: rlp.read(uint64),
    tail: rlp.read(uint64),
    next: rlp.read(Hash256),
  )

proc readImpl(rlp: var Rlp, T: type Progress): Progress {.raises: [RlpError].} =
  rlp.tryEnterList()
  Progress(
    segments: rlp.read(seq[Segment]),
    linked  : rlp.read(bool),
    canonicalHeadReset: rlp.read(bool),
  )

# ------------------------------------------------------------------------------
# Public functions
# ------------------------------------------------------------------------------

proc getHeader*(sk: SkeletonRef,
                number: uint64,
                onlySkeleton: bool = false): Result[Opt[BlockHeader], string] =
  ## Gets a block from the skeleton or canonical db by number.
  try:
    let rawHeader = sk.get(skeletonHeaderKey(number.BlockNumber))
    if rawHeader.len != 0:
      let output = rlp.decode(rawHeader, BlockHeader)
      return ok(Opt.some output)

    if onlySkeleton:
      return ok(Opt.none BlockHeader)

    # As a fallback, try to get the block from the canonical chain
    # in case it is available there
    var output: BlockHeader
    if sk.db.getBlockHeader(number.BlockNumber, output):
      return ok(Opt.some output)

    ok(Opt.none BlockHeader)
  except RlpError as ex:
    err(ex.msg)

proc getHeader*(sk: SkeletonRef,
                blockHash: Hash256,
                onlySkeleton: bool = false):
                  Result[Opt[BlockHeader], string] =
  ## Gets a skeleton block from the db by hash
  try:
    let rawNumber = sk.get(skeletonBlockHashToNumberKey(blockHash))
    if rawNumber.len != 0:
      var output: BlockHeader
      let number = rlp.decode(rawNumber, BlockNumber)
      if sk.db.getBlockHeader(number, output):
        return ok(Opt.some output)

    if onlySkeleton:
      return ok(Opt.none BlockHeader)

    # As a fallback, try to get the block from the canonical chain
    # in case it is available there
    var output: BlockHeader
    if sk.db.getBlockHeader(blockHash, output):
      return ok(Opt.some output)

    ok(Opt.none BlockHeader)
  except RlpError as ex:
    err(ex.msg)

proc putHeader*(sk: SkeletonRef, header: BlockHeader) =
  ## Writes a skeleton block header to the db by number
  let encodedHeader = rlp.encode(header)
  sk.put(skeletonHeaderKey(header.number), encodedHeader)
  sk.put(
    skeletonBlockHashToNumberKey(header.blockHash),
    rlp.encode(header.number)
  )

proc putBody*(sk: SkeletonRef, header: BlockHeader, body: BlockBody): Result[void, string] =
  ## Writes block body to db
  try:
    let
      encodedBody = rlp.encode(body)
      bodyHash    = sumHash(body)
      headerHash  = header.blockHash
      keyHash     = sumHash(headerHash, bodyHash)
    sk.put(skeletonBodyKey(keyHash), encodedBody)
    ok()
  except CatchableError as ex:
    err(ex.msg)

proc getBody*(sk: SkeletonRef, header: BlockHeader): Result[Opt[BlockBody], string] =
  ## Reads block body from db
  ## sumHash is the hash of [txRoot, ommersHash, wdRoot]
  try:
    let
      bodyHash   = header.sumHash
      headerHash = header.blockHash
      keyHash    = sumHash(headerHash, bodyHash)
      rawBody    = sk.get(skeletonBodyKey(keyHash))
    if rawBody.len > 0:
      return ok(Opt.some rlp.decode(rawBody, BlockBody))
    ok(Opt.none BlockBody)
  except RlpError as ex:
    err(ex.msg)

proc writeProgress*(sk: SkeletonRef) =
  ## Writes the progress to db
  for sub in sk.subchains:
    debug "Writing sync progress subchains", sub

  let encodedProgress = rlp.encode(sk.progress)
  sk.put(skeletonProgressKey(), encodedProgress)

proc readProgress*(sk: SkeletonRef): Result[void, string] =
  ## Reads the SkeletonProgress from db
  try:
    let rawProgress = sk.get(skeletonProgressKey())
    if rawProgress.len == 0:
      return ok()

    sk.progress = rlp.decode(rawProgress, Progress)
    ok()
  except RlpError as ex:
    err(ex.msg)

proc deleteHeaderAndBody*(sk: SkeletonRef, header: BlockHeader) =
  ## Deletes a skeleton block from the db by number
  sk.del(skeletonHeaderKey(header.number))
  sk.del(skeletonBlockHashToNumberKey(header.blockHash))
  sk.del(skeletonBodyKey(header.sumHash))

proc canonicalHead*(sk: SkeletonRef): BlockHeader =
  sk.chain.latestHeader

proc resetCanonicalHead*(sk: SkeletonRef, newHead, oldHead: uint64) =
  debug "RESET CANONICAL", newHead, oldHead
  sk.chain.com.syncCurrent = newHead.BlockNumber

proc insertBlocks*(sk: SkeletonRef,
                   blocks: openArray[EthBlock],
                   fromEngine: bool): Result[uint64, string] =
  for blk in blocks:
    ? sk.chain.importBlock(blk)
  ok(blocks.len.uint64)

proc insertBlock*(sk: SkeletonRef,
                  header: BlockHeader,
                  fromEngine: bool): Result[uint64, string] =
  let maybeBody = sk.getBody(header).valueOr:
    return err(error)
  if maybeBody.isNone:
    return err("insertBlock: Block body not found: " & $header.u64)
  sk.insertBlocks([EthBlock.init(header, maybeBody.get)], fromEngine)
