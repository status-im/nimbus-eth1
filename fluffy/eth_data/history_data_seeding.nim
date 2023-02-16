# # Nimbus - Portal Network
# # Copyright (c) 2022-2023 Status Research & Development GmbH
# # Licensed and distributed under either of
# #   * MIT license (license terms in the root directory or at https://opensource.org/licenses/MIT).
# #   * Apache v2 license (license terms in the root directory or at https://www.apache.org/licenses/LICENSE-2.0).
# # at your option. This file may not be copied, modified, or distributed except according to those terms.

{.push raises: [].}

import
  std/[strformat, os],
  stew/results, chronos, chronicles,
  eth/common/eth_types, eth/rlp,
  ../network/wire/portal_protocol,
  ../network/history/[history_content, history_network, accumulator],
  "."/[history_data_json_store, history_data_ssz_e2s]

export results

### Helper calls to seed the local database and/or the network

proc historyStore*(
    p: PortalProtocol, dataFile: string, verify = false):
    Result[void, string] =
  let blockData = ? readJsonType(dataFile, BlockDataTable)

  for b in blocks(blockData, verify):
    for value in b:
      let encKey = history_content.encode(value[0])
      # Note: This is the slowest part due to the hashing that takes place.
      p.storeContent(encKey, history_content.toContentId(encKey), value[1])

  ok()

proc propagateEpochAccumulator*(
    p: PortalProtocol, file: string):
    Future[Result[void, string]] {.async.} =
  ## Propagate a specific epoch accumulator into the network.
  ## file holds the SSZ serialized epoch accumulator.
  let epochAccumulatorRes = readEpochAccumulator(file)
  if epochAccumulatorRes.isErr():
    return err(epochAccumulatorRes.error)
  else:
    let
      accumulator = epochAccumulatorRes.get()
      rootHash = accumulator.hash_tree_root()
      key = ContentKey(
        contentType: epochAccumulator,
        epochAccumulatorKey: EpochAccumulatorKey(
          epochHash: rootHash))
      encKey = history_content.encode(key)
      # Note: The file actually holds the SSZ encoded accumulator, but we need
      # to decode as we need the root for the content key.
      encodedAccumulator = SSZ.encode(accumulator)
    info "Gossiping epoch accumulator", rootHash, contentKey = encKey

    p.storeContent(
      encKey,
      history_content.toContentId(encKey),
      encodedAccumulator
    )
    discard await p.neighborhoodGossip(
      ContentKeysList(@[encKey]), @[encodedAccumulator])

    return ok()

proc propagateEpochAccumulators*(
    p: PortalProtocol, path: string):
    Future[Result[void, string]] {.async.} =
  ## Propagate all epoch accumulators created when building the accumulator
  ## from the block headers.
  ## path is a directory that holds all SSZ encoded epoch accumulator files.
  for i in 0..<preMergeEpochs:
    let file =
      try: path / &"mainnet-epoch-accumulator-{i.uint64:05}.ssz"
      except ValueError as e: raiseAssert e.msg

    let res = await p.propagateEpochAccumulator(file)
    if res.isErr():
      return err(res.error)

  return ok()

proc historyPropagate*(
    p: PortalProtocol, dataFile: string, verify = false):
    Future[Result[void, string]] {.async.} =
  const concurrentGossips = 20

  var gossipQueue =
    newAsyncQueue[(ContentKeysList, seq[byte])](concurrentGossips)
  var gossipWorkers: seq[Future[void]]

  proc gossipWorker(p: PortalProtocol) {.async.} =
    while true:
      let (keys, content) = await gossipQueue.popFirst()

      discard await p.neighborhoodGossip(keys, @[content])

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
            (ContentKeysList(@[encode(value[0])]), value[1]))

    return ok()
  else:
    return err(blockData.error)

proc historyPropagateBlock*(
    p: PortalProtocol, dataFile: string, blockHash: string, verify = false):
    Future[Result[void, string]] {.async.} =
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

      discard await p.neighborhoodGossip(ContentKeysList(@[encode(value[0])]), @[value[1]])

    return ok()
  else:
    return err(blockDataTable.error)

proc historyPropagateHeadersWithProof*(
    p: PortalProtocol, epochHeadersFile: string, epochAccumulatorFile: string):
    Future[Result[void, string]] {.async.} =
  let res = readBlockHeaders(epochHeadersFile)
  if res.isErr():
    return err(res.error)

  let blockHeaders = res.get()

  let epochAccumulatorRes = readEpochAccumulatorCached(epochAccumulatorFile)
  if epochAccumulatorRes.isErr():
    return err(res.error)

  let epochAccumulator = epochAccumulatorRes.get()
  for header in blockHeaders:
    if header.isPreMerge():
      let headerWithProof = buildHeaderWithProof(header, epochAccumulator)
      if headerWithProof.isErr:
        return err(headerWithProof.error)

      let
        content = headerWithProof.get()
        contentKey = ContentKey(
          contentType: blockHeader,
          blockHeaderKey: BlockKey(blockHash: header.blockHash()))
        encKey = history_content.encode(contentKey)
        contentId = history_content.toContentId(encKey)
        encodedContent = SSZ.encode(content)

      p.storeContent(encKey, contentId, encodedContent)

      let keys = ContentKeysList(@[encode(contentKey)])
      discard await p.neighborhoodGossip(keys, @[encodedContent])

  return ok()

proc historyPropagateHeadersWithProof*(
    p: PortalProtocol, dataDir: string):
    Future[Result[void, string]] {.async.} =
  for i in 0..<preMergeEpochs:
    let
      epochHeadersfile =
        try: dataDir / &"mainnet-headers-epoch-{i.uint64:05}.e2s"
        except ValueError as e: raiseAssert e.msg
      epochAccumulatorFile =
        try: dataDir / &"mainnet-epoch-accumulator-{i.uint64:05}.ssz"
        except ValueError as e: raiseAssert e.msg

    let res = await p.historyPropagateHeadersWithProof(
      epochHeadersfile, epochAccumulatorFile)
    if res.isOk():
      info "Finished gossiping 1 epoch of headers with proof", i
    else:
      return err(res.error)

  return ok()

proc historyPropagateHeaders*(
    p: PortalProtocol, dataFile: string, verify = false):
    Future[Result[void, string]] {.async.} =
  # TODO: Should perhaps be integrated with `historyPropagate` call.
  const concurrentGossips = 20

  var gossipQueue =
    newAsyncQueue[(ContentKeysList, seq[byte])](concurrentGossips)
  var gossipWorkers: seq[Future[void]]

  proc gossipWorker(p: PortalProtocol) {.async.} =
    while true:
      let (keys, content) = await gossipQueue.popFirst()

      discard await p.neighborhoodGossip(keys, @[content])

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

      await gossipQueue.addLast(
        (ContentKeysList(@[encode(header[0])]), header[1]))

    return ok()
  else:
    return err(blockData.error)
