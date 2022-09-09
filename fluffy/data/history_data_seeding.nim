# # Nimbus - Portal Network
# # Copyright (c) 2022 Status Research & Development GmbH
# # Licensed and distributed under either of
# #   * MIT license (license terms in the root directory or at https://opensource.org/licenses/MIT).
# #   * Apache v2 license (license terms in the root directory or at https://www.apache.org/licenses/LICENSE-2.0).
# # at your option. This file may not be copied, modified, or distributed except according to those terms.

{.push raises: [Defect].}

import
  stew/results, chronos, chronicles,
  eth/common/eth_types,
  ../network/wire/portal_protocol,
  ../network/history/[history_content, accumulator],
  ./history_data_parser

export results

### Helper calls to seed the local database and/or the network

proc buildAccumulator*(dataFile: string): Result[Accumulator, string] =
  let blockData = ? readJsonType(dataFile, BlockDataTable)

  var headers: seq[BlockHeader]
  # Len of headers from blockdata + genesis header
  headers.setLen(blockData.len() + 1)

  headers[0] = getGenesisHeader()

  for k, v in blockData.pairs:
    let header = ? v.readBlockHeader()
    headers[header.blockNumber.truncate(int)] = header

  ok(buildAccumulator(headers))

proc buildAccumulatorData*(
    dataFile: string):
    Result[seq[(ContentKey, EpochAccumulator)], string] =
  let blockData = ? readJsonType(dataFile, BlockDataTable)

  var headers: seq[BlockHeader]
  # Len of headers from blockdata + genesis header
  headers.setLen(blockData.len() + 1)

  headers[0] = getGenesisHeader()

  for k, v in blockData.pairs:
    let header = ? v.readBlockHeader()
    headers[header.blockNumber.truncate(int)] = header

  ok(buildAccumulatorData(headers))

proc historyStore*(
    p: PortalProtocol, dataFile: string, verify = false):
    Result[void, string] =
  let blockData = ? readJsonType(dataFile, BlockDataTable)

  for b in blocks(blockData, verify):
    for value in b:
      # Note: This is the slowest part due to the hashing that takes place.
      p.storeContent(history_content.toContentId(value[0]), value[1])

  ok()

proc propagateAccumulatorData*(
    p: PortalProtocol, dataFile: string):
    Future[Result[void, string]] {.async.} =
  ## Propagate all epoch accumulators created when building the accumulator
  ## from the block headers.
  ## dataFile holds block data
  let epochAccumulators = buildAccumulatorData(dataFile)
  if epochAccumulators.isErr():
    return err(epochAccumulators.error)
  else:
    for (key, epochAccumulator) in epochAccumulators.get():
      let content = SSZ.encode(epochAccumulator)

      p.storeContent(
        history_content.toContentId(key), content)
      await p.neighborhoodGossip(
        ContentKeysList(@[encode(key)]), @[content])

    return ok()

proc propagateEpochAccumulator*(
    p: PortalProtocol, dataFile: string):
    Future[Result[void, string]] {.async.} =
  ## Propagate a specific epoch accumulator into the network.
  ## dataFile holds the SSZ serialized epoch accumulator
  let epochAccumulatorRes = readEpochAccumulator(dataFile)
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

    p.storeContent(
      history_content.toContentId(key), SSZ.encode(accumulator))
    await p.neighborhoodGossip(
      ContentKeysList(@[encode(key)]), @[SSZ.encode(accumulator)])

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

      await p.neighborhoodGossip(keys, @[content])

  for i in 0 ..< concurrentGossips:
    gossipWorkers.add(gossipWorker(p))

  let blockData = readJsonType(dataFile, BlockDataTable)
  if blockData.isOk():
    for b in blocks(blockData.get(), verify):
      for value in b:
        # Only sending non empty data, e.g. empty receipts are not send
        # TODO: Could do a similar thing for a combination of empty
        # txs and empty uncles, as then the serialization is always the same.
        if value[1].len() > 0:
          info "Seeding block content into the network", contentKey = value[0]
          # Note: This is the slowest part due to the hashing that takes place.
          let contentId = history_content.toContentId(value[0])
          p.storeContent(contentId, value[1])

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
      let contentId = history_content.toContentId(value[0])
      p.storeContent(contentId, value[1])

      await p.neighborhoodGossip(ContentKeysList(@[encode(value[0])]), @[value[1]])

    return ok()
  else:
    return err(blockDataTable.error)
