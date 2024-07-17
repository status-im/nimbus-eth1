# # Nimbus - Portal Network
# # Copyright (c) 2022-2024 Status Research & Development GmbH
# # Licensed and distributed under either of
# #   * MIT license (license terms in the root directory or at https://opensource.org/licenses/MIT).
# #   * Apache v2 license (license terms in the root directory or at https://www.apache.org/licenses/LICENSE-2.0).
# # at your option. This file may not be copied, modified, or distributed except according to those terms.

{.push raises: [].}

import
  std/[strformat, os],
  results,
  chronos,
  chronicles,
  eth/common/eth_types,
  eth/rlp,
  ../network/wire/portal_protocol,
  ../network/history/[history_content, history_network, accumulator],
  "."/[era1, history_data_json_store, history_data_ssz_e2s]

export results

### Helper calls to seed the local database and/or the network

proc historyStore*(
    p: PortalProtocol, dataFile: string, verify = false
): Result[void, string] =
  let blockData = ?readJsonType(dataFile, BlockDataTable)

  for b in blocks(blockData, verify):
    for value in b:
      let encKey = history_content.encode(value[0])
      # Note: This is the slowest part due to the hashing that takes place.
      p.storeContent(encKey, history_content.toContentId(encKey), value[1])

  ok()

proc propagateEpochRecord*(
    p: PortalProtocol, file: string
): Future[Result[void, string]] {.async.} =
  ## Propagate a specific epoch accumulator into the network.
  ## file holds the SSZ serialized epoch accumulator.
  let epochRecordRes = readEpochRecord(file)
  if epochRecordRes.isErr():
    return err(epochRecordRes.error)
  else:
    let
      epochRecord = epochRecordRes.get()
      rootHash = epochRecord.hash_tree_root()
      key = ContentKey(
        contentType: epochRecord, epochRecordKey: EpochRecordKey(epochHash: rootHash)
      )
      encKey = history_content.encode(key)
      # Note: The file actually holds the SSZ encoded accumulator, but we need
      # to decode as we need the root for the content key.
      encodedEpochRecord = SSZ.encode(epochRecord)
    info "Gossiping epoch record", rootHash, contentKey = encKey

    p.storeContent(encKey, history_content.toContentId(encKey), encodedEpochRecord)
    discard await p.neighborhoodGossip(
      Opt.none(NodeId), ContentKeysList(@[encKey]), @[encodedEpochRecord]
    )

    return ok()

proc propagateEpochRecords*(
    p: PortalProtocol, path: string
): Future[Result[void, string]] {.async.} =
  ## Propagate all epoch accumulators created when building the accumulator
  ## from the block headers.
  ## path is a directory that holds all SSZ encoded epoch accumulator files.
  for i in 0 ..< preMergeEpochs:
    let file =
      try:
        path / &"mainnet-epoch-record-{i.uint64:05}.ssz"
      except ValueError as e:
        raiseAssert e.msg

    let res = await p.propagateEpochRecord(file)
    if res.isErr():
      return err(res.error)

  return ok()

proc historyPropagate*(
    p: PortalProtocol, dataFile: string, verify = false
): Future[Result[void, string]] {.async.} =
  const concurrentGossips = 20

  var gossipQueue =
    newAsyncQueue[(Opt[NodeId], ContentKeysList, seq[byte])](concurrentGossips)
  var gossipWorkers: seq[Future[void]]

  proc gossipWorker(p: PortalProtocol) {.async.} =
    while true:
      let (srcNodeId, keys, content) = await gossipQueue.popFirst()

      discard await p.neighborhoodGossip(srcNodeId, keys, @[content])

  for i in 0 ..< concurrentGossips:
    gossipWorkers.add(gossipWorker(p))

  let blockData = readJsonType(dataFile, BlockDataTable)
  if blockData.isOk():
    for b in blocks(blockData.get(), verify):
      for i, value in b:
        if i == 0:
          # Note: Skipping propagation of headers here as they should be offered
          # separately to be certain that bodies and receipts can be verified.
          # TODO: Rename this chain of calls to be more clear about this and
          # adjust the interator call.
          continue
        # Only sending non empty data, e.g. empty receipts are not send
        # TODO: Could do a similar thing for a combination of empty
        # txs and empty uncles, as then the serialization is always the same.
        if value[1].len() > 0:
          info "Seeding block content into the network", contentKey = value[0]
          # Note: This is the slowest part due to the hashing that takes place.
          let
            encKey = history_content.encode(value[0])
            contentId = history_content.toContentId(encKey)
          p.storeContent(encKey, contentId, value[1])

          await gossipQueue.addLast(
            (Opt.none(NodeId), ContentKeysList(@[encode(value[0])]), value[1])
          )

    return ok()
  else:
    return err(blockData.error)

proc historyPropagateBlock*(
    p: PortalProtocol, dataFile: string, blockHash: string, verify = false
): Future[Result[void, string]] {.async.} =
  let blockDataTable = readJsonType(dataFile, BlockDataTable)

  if blockDataTable.isOk():
    let b =
      try:
        blockDataTable.get()[blockHash]
      except KeyError:
        return err("Block hash not found in block data file")

    let blockDataRes = readBlockData(blockHash, b)
    if blockDataRes.isErr:
      return err(blockDataRes.error)

    let blockData = blockDataRes.get()

    for value in blockData:
      info "Seeding block content into the network", contentKey = value[0]
      let
        encKey = history_content.encode(value[0])
        contentId = history_content.toContentId(encKey)
      p.storeContent(encKey, contentId, value[1])

      discard await p.neighborhoodGossip(
        Opt.none(NodeId), ContentKeysList(@[encode(value[0])]), @[value[1]]
      )

    return ok()
  else:
    return err(blockDataTable.error)

proc historyPropagateHeadersWithProof*(
    p: PortalProtocol, epochHeadersFile: string, epochRecordFile: string
): Future[Result[void, string]] {.async.} =
  let res = readBlockHeaders(epochHeadersFile)
  if res.isErr():
    return err(res.error)

  let blockHeaders = res.get()

  let epochRecordRes = readEpochRecordCached(epochRecordFile)
  if epochRecordRes.isErr():
    return err(res.error)

  let epochRecord = epochRecordRes.get()
  for header in blockHeaders:
    if header.isPreMerge():
      let headerWithProof = buildHeaderWithProof(header, epochRecord)
      if headerWithProof.isErr:
        return err(headerWithProof.error)

      let
        content = headerWithProof.get()
        contentKey = ContentKey(
          contentType: blockHeader,
          blockHeaderKey: BlockKey(blockHash: header.blockHash()),
        )
        encKey = history_content.encode(contentKey)
        contentId = history_content.toContentId(encKey)
        encodedContent = SSZ.encode(content)

      p.storeContent(encKey, contentId, encodedContent)

      let keys = ContentKeysList(@[encode(contentKey)])
      discard await p.neighborhoodGossip(Opt.none(NodeId), keys, @[encodedContent])

  return ok()

proc historyPropagateHeadersWithProof*(
    p: PortalProtocol, dataDir: string
): Future[Result[void, string]] {.async.} =
  for i in 0 ..< preMergeEpochs:
    let
      epochHeadersfile =
        try:
          dataDir / &"mainnet-headers-epoch-{i.uint64:05}.e2s"
        except ValueError as e:
          raiseAssert e.msg
      epochRecordFile =
        try:
          dataDir / &"mainnet-epoch-record-{i.uint64:05}.ssz"
        except ValueError as e:
          raiseAssert e.msg

    let res =
      await p.historyPropagateHeadersWithProof(epochHeadersfile, epochRecordFile)
    if res.isOk():
      info "Finished gossiping 1 epoch of headers with proof", i
    else:
      return err(res.error)

  return ok()

proc historyPropagateHeaders*(
    p: PortalProtocol, dataFile: string, verify = false
): Future[Result[void, string]] {.async.} =
  # TODO: Should perhaps be integrated with `historyPropagate` call.
  const concurrentGossips = 20

  var gossipQueue = newAsyncQueue[(ContentKeysList, seq[byte])](concurrentGossips)
  var gossipWorkers: seq[Future[void]]

  proc gossipWorker(p: PortalProtocol) {.async.} =
    while true:
      let (keys, content) = await gossipQueue.popFirst()

      discard await p.neighborhoodGossip(Opt.none(NodeId), keys, @[content])

  for i in 0 ..< concurrentGossips:
    gossipWorkers.add(gossipWorker(p))

  let blockData = readJsonType(dataFile, BlockDataTable)
  if blockData.isOk():
    for header in headers(blockData.get(), verify):
      info "Seeding header content into the network", contentKey = header[0]
      let
        encKey = history_content.encode(header[0])
        contentId = history_content.toContentId(encKey)
      p.storeContent(encKey, contentId, header[1])

      await gossipQueue.addLast((ContentKeysList(@[encode(header[0])]), header[1]))

    return ok()
  else:
    return err(blockData.error)

##
## Era1 based iterators that encode to Portal content
##

# Note: these iterators + the era1 iterators will assert on error. These asserts
# would indicate corrupt/invalid era1 files. We might want to instead break,
# raise an exception or return a Result type instead, but the latter does not
# have great support for usage in iterators.

iterator headersWithProof*(
    f: Era1File, epochRecord: EpochRecordCached
): (ContentKeyByteList, seq[byte]) =
  for blockHeader in f.era1BlockHeaders:
    doAssert blockHeader.isPreMerge()

    let
      contentKey = ContentKey(
        contentType: blockHeader,
        blockHeaderKey: BlockKey(blockHash: blockHeader.blockHash()),
      ).encode()

      headerWithProof = buildHeaderWithProof(blockHeader, epochRecord).valueOr:
        raiseAssert "Failed to build header with proof: " & $blockHeader.number

      contentValue = SSZ.encode(headerWithProof)

    yield (contentKey, contentValue)

iterator blockContent*(f: Era1File): (ContentKeyByteList, seq[byte]) =
  for (header, body, receipts, _) in f.era1BlockTuples:
    let blockHash = header.blockHash()

    block: # block body
      let
        contentKey = ContentKey(
          contentType: blockBody, blockBodyKey: BlockKey(blockHash: blockHash)
        ).encode()

        contentValue = encode(body)

      yield (contentKey, contentValue)

    block: # receipts
      let
        contentKey = ContentKey(
          contentType: receipts, receiptsKey: BlockKey(blockHash: blockHash)
        ).encode()

        contentValue = encode(receipts)

      yield (contentKey, contentValue)

##
## Era1 based Gossip calls
##

proc historyGossipHeadersWithProof*(
    p: PortalProtocol, era1File: string, epochRecordFile: Opt[string], verifyEra = false
): Future[Result[void, string]] {.async.} =
  let f = ?Era1File.open(era1File)

  if verifyEra:
    let _ = ?f.verify()

  # Note: building the accumulator takes about 150ms vs 10ms for reading it,
  # so it is probably not really worth using the read version considering the
  # UX hassle it adds to provide the accumulator ssz files.
  let epochRecord =
    if epochRecordFile.isNone:
      ?f.buildAccumulator()
    else:
      ?readEpochRecordCached(epochRecordFile.get())

  for (contentKey, contentValue) in f.headersWithProof(epochRecord):
    let peers = await p.neighborhoodGossip(
      Opt.none(NodeId), ContentKeysList(@[contentKey]), @[contentValue]
    )
    info "Gossiped block header", contentKey, peers

  ok()

proc historyGossipBlockContent*(
    p: PortalProtocol, era1File: string, verifyEra = false
): Future[Result[void, string]] {.async.} =
  let f = ?Era1File.open(era1File)

  if verifyEra:
    let _ = ?f.verify()

  for (contentKey, contentValue) in f.blockContent():
    let peers = await p.neighborhoodGossip(
      Opt.none(NodeId), ContentKeysList(@[contentKey]), @[contentValue]
    )
    info "Gossiped block content", contentKey, peers

  ok()
