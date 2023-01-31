# Nimbus
# Copyright (c) 2022-2023 Status Research & Development GmbH
# Licensed and distributed under either of
#   * MIT license (license terms in the root directory or at https://opensource.org/licenses/MIT).
#   * Apache v2 license (license terms in the root directory or at https://www.apache.org/licenses/LICENSE-2.0).
# at your option. This file may not be copied, modified, or distributed except according to those terms.

{.push raises: [].}

import
  std/math,
  chronos,
  eth/p2p/discoveryv5/[node, random2],
  ./wire/portal_protocol,
  ./history/[history_content, history_network],
  ../seed_db

# Experimental module which implements different content seeding strategies.
# Module is oblivious to content stored in seed database as all content related
# parameters should be available in seed db i.e (contentId, contentKey, content)
# One thing which might need to be parameterized per network basis in the future is
# the distance function.
# TODO: At this point all calls are one shot calls but we can also experiment with
# approaches which start some process which continuously seeds data.
# This would require creation of separate object which would manage started task
# like:
# type NetworkSeedingManager = ref object
#   seedTask: Future[void]
# and creating few procs which would start/stop given seedTask or even few
# seed tasks

const
  #TODO currently we are using value for history network, but this should be
  #caluculated per netowork basis
  maxItemsPerOfferBySize = getMaxOfferedContentKeys(
    uint32(len(history_network.historyProtocolId)),
    uint32(history_content.maxContentKeySize)
  )

  # Offering is restricted to max 64 items
  maxItemPerOfferByLen = 64

  maxItemsPerOffer = min(maxItemsPerOfferBySize, maxItemPerOfferByLen)

proc depthContentPropagate*(
    p: PortalProtocol, seedDbPath: string, maxClosestNodes: uint32):
    Future[Result[void, string]] {.async.} =

  ## Choses `maxClosestNodes` closest known nodes with known radius and tries to
  ## offer as much content as possible in their range from seed db. Offers are made conccurently
  ## with at most one offer per peer at the time.

  const batchSize = maxItemsPerOffer

  var gossipWorkers: seq[Future[void]]

  # TODO improve peer selection strategy, to be sure more network is covered, although
  # it still does not need to be perfect as nodes which receive content will still
  # propagate it further by neighbour gossip
  let closestWithRadius = p.getNClosestNodesWithRadius(
    p.localNode.id,
    int(maxClosestNodes),
    seenOnly = true
  )

  proc worker(p: PortalProtocol, db: SeedDb, node: Node, radius: UInt256): Future[void] {.async.} =
    var offset = 0
    while true:
      let content = db.getContentInRange(node.id, radius, batchSize, offset)

      if len(content) == 0:
        break

      var contentInfo: seq[ContentInfo]
      for e in content:
        let info = ContentInfo(contentKey: ByteList.init(e.contentKey), content: e.content)
        contentInfo.add(info)

      let offerResult = await p.offer(node, contentInfo)

      if offerResult.isErr() or len(content) < batchSize:
        # peer failed or we reached end of database stop offering more content
        break

      offset = offset + batchSize

  proc saveDataToLocalDb(p: PortalProtocol, db: SeedDb) =
    let localBatchSize = 10000

    var offset = 0
    while true:
      let content = db.getContentInRange(p.localNode.id, p.dataRadius, localBatchSize, offset)

      if len(content) == 0:
        break

      for e in content:
        p.storeContent(
          ByteList.init(e.contentKey),
          UInt256.fromBytesBE(e.contentId),
          e.content
        )

      if len(content) < localBatchSize:
        # got to the end of db.
        break

      offset = offset + localBatchSize

  let maybePathAndDbName = getDbBasePathAndName(seedDbPath)

  if maybePathAndDbName.isNone():
    return err("Provided path is not valid sqlite database path")

  let
    (dbPath, dbName) = maybePathAndDbName.unsafeGet()
    db = SeedDb.new(path = dbPath, name = dbName)

  for n in closestWithRadius:
    gossipWorkers.add(p.worker(db, n[0], n[1]))

  p.saveDataToLocalDb(db)

  await allFutures(gossipWorkers)

  db.close()

  return ok()

func contentDataToKeys(contentData: seq[ContentDataDist]): (ContentKeysList, seq[seq[byte]]) =
  var contentKeys: seq[ByteList]
  var content: seq[seq[byte]]
  for cd in contentData:
    contentKeys.add(ByteList.init(cd.contentKey))
    content.add(cd.content)
  return (ContentKeysList(contentKeys), content)

proc breadthContentPropagate*(
    p: PortalProtocol, seedDbPath: string):
    Future[Result[void, string]] {.async.} =

  ## Iterates over whole seed database, and offer batches of content to different
  ## set of nodes

  const concurrentGossips = 20

  const gossipsPerBatch = 5

  var gossipQueue =
    newAsyncQueue[(ContentKeysList, seq[seq[byte]])](concurrentGossips)

  var gossipWorkers: seq[Future[void]]

  proc gossipWorker(p: PortalProtocol) {.async.} =
    while true:
      let (keys, content) = await gossipQueue.popFirst()

      discard await p.neighborhoodGossip(keys, content)

  for i in 0 ..< concurrentGossips:
    gossipWorkers.add(gossipWorker(p))

  let maybePathAndDbName = getDbBasePathAndName(seedDbPath)

  if maybePathAndDbName.isNone():
    return err("Provided path is not valid sqlite database path")

  let
    (dbPath, dbName) = maybePathAndDbName.unsafeGet()
    batchSize = maxItemsPerOffer
    db = SeedDb.new(path = dbPath, name = dbName)
    target = p.localNode.id

  var offset = 0

  while true:
    # Setting radius to `UInt256.high` and using batchSize and offset, means
    # we will iterate over whole database in batches of `maxItemsPerOffer` items
    var contentData = db.getContentInRange(target, UInt256.high, batchSize, offset)

    if len(contentData) == 0:
      break

    for cd in contentData:
      p.storeContent(
        ByteList.init(cd.contentKey),
        UInt256.fromBytesBE(cd.contentId),
        cd.content
      )

    # TODO this a bit hacky way to make sure we will engage more valid peers for each
    # batch of data. This maybe removed after improving neighborhoodGossip
    # to better chose peers based on propagated content
    for i in 0 ..< gossipsPerBatch:
      p.baseProtocol.rng[].shuffle(contentData)
      let keysWithContent = contentDataToKeys(contentData)
      await gossipQueue.put(keysWithContent)

    if len(contentData) < batchSize:
      break

    offset = offset + batchSize

  db.close()

  return ok()

proc offerContentInNodeRange*(
    p: PortalProtocol,
    seedDbPath: string,
    nodeId: NodeId,
    max: uint32,
    starting: uint32):  Future[PortalResult[int]] {.async.} =
  ## Offers `max` closest elements starting from `starting` index to peer
  ## with given `nodeId`.
  ## Maximum value of `max` is 64 , as this is limit for single offer. Although
  ## `starting` argument is needed as seed_db is read only, so if there is
  ## more content in peer range than max, then to offer 64 closest elements
  ## it needs to be set to 0. To offer next 64 elements it need to be set to
  ## 64 etc.
  ## Return number of items really offered to remote peer.

  let numberToToOffer = min(int(max), maxItemsPerOffer)

  let maybePathAndDbName = getDbBasePathAndName(seedDbPath)

  if maybePathAndDbName.isNone():
    return err("Provided path is not valid sqlite database path")

  let (dbPath, dbName) = maybePathAndDbName.unsafeGet()

  let maybeNodeAndRadius = await p.resolveWithRadius(nodeId)

  if maybeNodeAndRadius.isNone():
    return err("Could not find node with provided nodeId")

  let
    db = SeedDb.new(path = dbPath, name = dbName)
    (node, radius) = maybeNodeAndRadius.unsafeGet()
    content = db.getContentInRange(node.id, radius, int64(numberToToOffer), int64(starting))

  # We got all we wanted from seed_db, it can be closed now.
  db.close()

  var ci: seq[ContentInfo]

  for cont in content:
    let k = ByteList.init(cont.contentKey)
    let info = ContentInfo(contentKey: k, content: cont.content)
    ci.add(info)

  # waiting for offer result, by the end of this call remote node should
  # have received offered content
  let offerResult = await p.offer(node, ci)

  if offerResult.isOk():
    return ok(len(content))
  else:
    return err(offerResult.error)

proc storeContentInNodeRange*(
    p: PortalProtocol,
    seedDbPath: string,
    max: uint32,
    starting: uint32): PortalResult[void] =
  let maybePathAndDbName = getDbBasePathAndName(seedDbPath)

  if maybePathAndDbName.isNone():
    return err("Provided path is not valid sqlite database path")

  let (dbPath, dbName) = maybePathAndDbName.unsafeGet()

  let
    localRadius = p.dataRadius
    db = SeedDb.new(path = dbPath, name = dbName)
    localId = p.localNode.id
    contentInRange = db.getContentInRange(localId, localRadius, int64(max), int64(starting))

  db.close()

  for contentData in contentInRange:
    let cid = UInt256.fromBytesBE(contentData.contentId)
    p.storeContent(
      ByteList.init(contentData.contentKey),
      cid,
      contentData.content
    )

  return ok()
