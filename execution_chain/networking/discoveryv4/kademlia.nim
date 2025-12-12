# nimbus-execution-client
# Copyright (c) 2018-2025 Status Research & Development GmbH
# Licensed under either of
#  * Apache License, version 2.0, ([LICENSE-APACHE](LICENSE-APACHE))
#  * MIT license ([LICENSE-MIT](LICENSE-MIT))
# at your option.
# This file may not be copied, modified, or distributed except according to
# those terms.
{.push raises: [].}

import
  std/[tables, hashes, times, algorithm, sets, sequtils],
  chronos, chronicles, stint, eth/keccak/keccak, metrics, results,
  eth/common/keys, eth/p2p/discoveryv5/random2,
  eth/enode/enode

export enode, sets

declareGauge discv4_routing_table_nodes,
  "Discovery v4 routing table nodes"

logScope:
  topics = "p2p kademlia"

type
  # 32 bytes NodeId | 16 bytes ip | 1 byte mode
  TimeKey = array[49, byte]

  KademliaProtocol* [Wire] = ref object
    wire: Wire
    thisNode: Node
    routing: RoutingTable
    pongFutures: Table[seq[byte], Future[bool]]
    pingFutures: Table[Node, Future[bool]]
    neighboursCallbacks: Table[Node, proc(n: seq[Node]) {.gcsafe, raises: [].}]
    rng: ref HmacDrbgContext
    pingPongTime: OrderedTable[TimeKey, int64] # int64 -> unix time

  NodeId* = UInt256

  Node* = ref object
    node*: ENode
    id*: NodeId

  RoutingTable = object
    thisNode: Node
    buckets: seq[KBucket]

  KBucket = ref object
    istart, iend: UInt256
    nodes: seq[Node]
    replacementCache: seq[Node]

  CommandId* = enum
    cmdPing = 1
    cmdPong = 2
    cmdFindNode = 3
    cmdNeighbours = 4
    cmdENRRequest = 5
    cmdENRResponse = 6

const
  BUCKET_SIZE = 16
  BITS_PER_HOP = 8
  REQUEST_TIMEOUT = chronos.milliseconds(5000) # timeout of message round trips
  FIND_CONCURRENCY = 3                  # parallel find node lookups
  ID_SIZE = 256
  BOND_EXPIRATION = initDuration(hours = 12)

proc len(r: RoutingTable): int

proc toNodeId*(pk: PublicKey): NodeId =
  readUintBE[256](Keccak256.digest(pk.toRaw()).data)

proc newNode*(pk: PublicKey, address: Address): Node =
  result.new()
  result.node = ENode(pubkey: pk, address: address)
  result.id = pk.toNodeId()

proc newNode*(uriString: string): Node =
  result.new()
  result.node = ENode.fromString(uriString)[]
  result.id = result.node.pubkey.toNodeId()

proc newNode*(enode: ENode): Node =
  result.new()
  result.node = enode
  result.id = result.node.pubkey.toNodeId()

proc distanceTo(n: Node, id: NodeId): UInt256 = n.id xor id

proc `$`*(n: Node): string =
  if n == nil:
    "Node[local]"
  else:
    "Node[" & $n.node.address.ip & ":" & $n.node.address.udpPort & "]"

chronicles.formatIt(Node): $it
chronicles.formatIt(seq[Node]): $it

proc hash*(n: Node): hashes.Hash = hash(n.node.pubkey.toRaw)
proc `==`*(a, b: Node): bool = (a.isNil and b.isNil) or
  (not a.isNil and not b.isNil and a.node.pubkey == b.node.pubkey)

proc timeKey(id: NodeId, ip: IpAddress, cmd: CommandId): TimeKey =
  result[0..31] = id.toBytesBE()[0..31]
  case ip.family
  of IpAddressFamily.IPv6:
    result[32..47] = ip.address_v6[0..15]
  of IpAddressFamily.IPv4:
    result[32..35] = ip.address_v4[0..3]
  result[48] = cmd.byte

proc ip(n: Node): IpAddress =
  n.node.address.ip

proc timeKeyPong(n: Node): TimeKey =
  timeKey(n.id, n.ip, cmdPong)

proc timeKeyPing(n: Node): TimeKey =
  timeKey(n.id, n.ip, cmdPing)

when false:
  proc lastPingReceived(k: KademliaProtocol, n: Node): Time =
    k.pingPongTime.getOrDefault(n.timeKeyPing, 0'i64).fromUnix

proc lastPongReceived(k: KademliaProtocol, n: Node): Time =
  k.pingPongTime.getOrDefault(n.timeKeyPong, 0'i64).fromUnix

proc cmp(x, y: (TimeKey, int64)): int =
  if x[1] < y[1]: return -1
  if x[1] > y[1]: return 1
  0

proc removeTooOldPingPongTime(k: KademliaProtocol) =
  const
    MinEntries = 128
    MaxRC = MinEntries div 8

  # instead of using fixed limit, we use dynamic limit
  # with minimum entries = 128.
  # remove 25% of too old entries if we need more space.
  # the reason maxEntries is twice routing table because we
  # store ping and pong time.
  let
    maxEntries = max(k.routing.len * 2, MinEntries)
    maxRemove = maxEntries div 4

  if k.pingPongTime.len < maxEntries:
    return

  # it is safe to remove this table sort?
  # because we already using ordered table to store time from
  # older value to newer value
  when false:
    k.pingPongTime.sort(cmp, order = SortOrder.Descending)

  var
    rci = 0
    numRemoved = 0
    rc: array[MaxRC, TimeKey] # 784 bytes(MinEntries/8*sizeof(TimeKey))

  # using fixed size temp on stack possibly
  # requires multiple iteration to remove
  # old entries
  while numRemoved < maxRemove:
    for v in keys(k.pingPongTime):
      rc[rci] = v
      inc rci
      inc numRemoved
      if rci >= MaxRC or numRemoved >= maxRemove: break

    for i in 0..<rci:
      k.pingPongTime.del(rc[i])

    rci = 0

proc updateLastPingReceived(k: KademliaProtocol, n: Node, t: Time) =
  k.removeTooOldPingPongTime()
  k.pingPongTime[n.timeKeyPing] = t.toUnix

proc updateLastPongReceived(k: KademliaProtocol, n: Node, t: Time) =
  k.removeTooOldPingPongTime()
  k.pingPongTime[n.timeKeyPong] = t.toUnix

when false:
  # checkBond checks if the given node has a recent enough endpoint proof.
  proc checkBond(k: KademliaProtocol, n: Node): bool =
    getTime() - k.lastPongReceived(n) < BOND_EXPIRATION

proc newKBucket(istart, iend: NodeId): KBucket =
  result.new()
  result.istart = istart
  result.iend = iend
  result.nodes = @[]
  result.replacementCache = @[]

proc midpoint(k: KBucket): NodeId =
  k.istart + (k.iend - k.istart) div 2.u256

proc distanceTo(k: KBucket, id: NodeId): UInt256 = k.midpoint xor id
proc nodesByDistanceTo(k: KBucket, id: NodeId): seq[Node] =
  sortedByIt(k.nodes, it.distanceTo(id))

proc len(k: KBucket): int = k.nodes.len
proc head(k: KBucket): Node = k.nodes[0]

proc add(k: KBucket, n: Node): Node =
  ## Try to add the given node to this bucket.

  ## If the node is already present, it is moved to the tail of the list, and we return None.

  ## If the node is not already present and the bucket has fewer than k entries, it is inserted
  ## at the tail of the list, and we return None.

  ## If the bucket is full, we add the node to the bucket's replacement cache and return the
  ## node at the head of the list (i.e. the least recently seen), which should be evicted if it
  ## fails to respond to a ping.
  let nodeIdx = k.nodes.find(n)
  if nodeIdx != -1:
      k.nodes.delete(nodeIdx)
      k.nodes.add(n)
  elif k.len < BUCKET_SIZE:
      k.nodes.add(n)
      discv4_routing_table_nodes.inc()
  else:
      k.replacementCache.add(n)
      return k.head
  return nil

proc removeNode(k: KBucket, n: Node) =
  let i = k.nodes.find(n)
  if i != -1:
    discv4_routing_table_nodes.dec()
    k.nodes.delete(i)

proc split(k: KBucket): tuple[lower, upper: KBucket] =
  ## Split at the median id
  let splitid = k.midpoint
  result.lower = newKBucket(k.istart, splitid)
  result.upper = newKBucket(splitid + 1.u256, k.iend)
  for node in k.nodes:
    let bucket = if node.id <= splitid: result.lower else: result.upper
    discard bucket.add(node)
  for node in k.replacementCache:
    let bucket = if node.id <= splitid: result.lower else: result.upper
    bucket.replacementCache.add(node)

proc inRange(k: KBucket, n: Node): bool =
  k.istart <= n.id and n.id <= k.iend

proc isFull(k: KBucket): bool = k.len == BUCKET_SIZE

proc contains(k: KBucket, n: Node): bool = n in k.nodes

proc binaryGetBucketForNode(buckets: openArray[KBucket], n: Node): Result[KBucket, cstring] =
  ## Given a list of ordered buckets, returns the bucket for a given node.
  let bucketPos = lowerBound(buckets, n.id) do(a: KBucket, b: NodeId) -> int:
    cmp(a.iend, b)
  # Prevents edge cases where bisect_left returns an out of range index
  if bucketPos < buckets.len:
    let bucket = buckets[bucketPos]
    if bucket.istart <= n.id and n.id <= bucket.iend:
      return ok(bucket)

  err("kademlia: No bucket found")

proc computeSharedPrefixBits(nodes: openArray[Node]): int =
  ## Count the number of prefix bits shared by all nodes.
  if nodes.len < 2:
    return ID_SIZE

  var mask = zero(UInt256)
  let one = one(UInt256)

  for i in 1 .. ID_SIZE:
    mask = mask or (one shl (ID_SIZE - i))
    let reference = nodes[0].id and mask
    for j in 1 .. nodes.high:
      if (nodes[j].id and mask) != reference: return i - 1

  doAssert(false, "Unable to calculate number of shared prefix bits")

proc init(r: var RoutingTable, thisNode: Node) =
  r.thisNode = thisNode
  r.buckets = @[newKBucket(0.u256, high(UInt256))]

proc splitBucket(r: var RoutingTable, index: int) =
  let bucket = r.buckets[index]
  let (a, b) = bucket.split()
  r.buckets[index] = a
  r.buckets.insert(b, index + 1)

proc bucketForNode(r: RoutingTable, n: Node): Result[KBucket, cstring] =
  binaryGetBucketForNode(r.buckets, n)

proc removeNode(r: var RoutingTable, n: Node): Result[void, cstring] =
  let bucket = r.bucketForNode(n).valueOr:
    return err(error)
  bucket.removeNode(n)
  ok()

proc addNode(r: var RoutingTable, n: Node): Result[Node, cstring] =
  if n == r.thisNode:
    warn "Trying to add ourselves to the routing table", node = n
    return ok(nil)
  let bucket = ?r.bucketForNode(n)
  let evictionCandidate = bucket.add(n)
  if not evictionCandidate.isNil:
    # Split if the bucket has the local node in its range or if the depth is not congruent
    # to 0 mod BITS_PER_HOP

    let depth = computeSharedPrefixBits(bucket.nodes)
    if bucket.inRange(r.thisNode) or (depth mod BITS_PER_HOP != 0 and depth != ID_SIZE):
      r.splitBucket(r.buckets.find(bucket))
      return r.addNode(n) # retry

    # Nothing added, ping evictionCandidate
    return ok(evictionCandidate)
  ok(nil)

proc contains(r: RoutingTable, n: Node): bool =
  let bucket = r.bucketForNode(n).valueOr:
    return false
  n in bucket

proc bucketsByDistanceTo(r: RoutingTable, id: NodeId): seq[KBucket] =
  sortedByIt(r.buckets, it.distanceTo(id))

proc notFullBuckets(r: RoutingTable): seq[KBucket] =
  r.buckets.filterIt(not it.isFull)

proc neighbours(r: RoutingTable, id: NodeId, k: int = BUCKET_SIZE): seq[Node] =
  ## Return up to k neighbours of the given node.
  result = newSeqOfCap[Node](k * 2)
  for bucket in r.bucketsByDistanceTo(id):
    for n in bucket.nodesByDistanceTo(id):
      if n.id != id:
        result.add(n)
        if result.len == k * 2:
          break
  result = sortedByIt(result, it.distanceTo(id))
  if result.len > k:
    result.setLen(k)

proc len(r: RoutingTable): int =
  for b in r.buckets: result += b.len

proc newKademliaProtocol*[Wire](
    thisNode: Node, wire: Wire, rng = newRng()): KademliaProtocol[Wire] =
  if rng == nil: raiseAssert "Need an RNG" # doAssert gives compile error on mac

  result.new()
  result.thisNode = thisNode
  result.wire = wire
  result.routing.init(thisNode)
  result.rng = rng

proc bond(k: KademliaProtocol, n: Node): Future[bool] {.gcsafe, async: (raises: [CancelledError]).}
proc bondDiscard(k: KademliaProtocol, n: Node): Future[void] {.async: (raises: [CancelledError]).}

proc updateRoutingTable(k: KademliaProtocol, n: Node): Result[void, cstring] {.gcsafe.} =
  ## Update the routing table entry for the given node.
  let evictionCandidate = ?k.routing.addNode(n)
  if not evictionCandidate.isNil:
    # This means we couldn't add the node because its bucket is full, so schedule a bond()
    # with the least recently seen node on that bucket. If the bonding fails the node will
    # be removed from the bucket and a new one will be picked from the bucket's
    # replacement cache.
    asyncSpawn k.bondDiscard(evictionCandidate)
  ok()

proc doSleep(p: proc() {.gcsafe, raises: [].}) {.async: (raises: [CancelledError]).} =
  await sleepAsync(REQUEST_TIMEOUT)
  p()

template onTimeout(b: untyped) =
  asyncSpawn doSleep() do():
    b

proc pingId(n: Node, token: seq[byte]): seq[byte] =
  result = token & @(n.node.pubkey.toRaw)

proc initFuture[T](loc: var Future[T], name: static[string]) =
  loc = newFuture[T](name)

proc waitPong(k: KademliaProtocol, n: Node, pingid: seq[byte]): Future[bool].Raising([CancelledError]) =
  doAssert(pingid notin k.pongFutures, "Already waiting for pong from " & $n)
  result.initFuture("waitPong")
  let fut = result
  k.pongFutures[pingid] = result
  onTimeout:
    if not fut.finished:
      k.pongFutures.del(pingid)
      fut.complete(false)

proc ping(k: KademliaProtocol, n: Node): seq[byte] =
  doAssert(n != k.thisNode)
  result = k.wire.sendPing(n)

proc waitPing(k: KademliaProtocol, n: Node): Future[bool].Raising([CancelledError]) =
  result.initFuture("waitPing")
  doAssert(n notin k.pingFutures)
  k.pingFutures[n] = result
  let fut = result
  onTimeout:
    if not fut.finished:
      k.pingFutures.del(n)
      fut.complete(false)

proc waitNeighbours(k: KademliaProtocol, remote: Node): Future[seq[Node]].Raising([CancelledError]) =
  doAssert(remote notin k.neighboursCallbacks)
  result.initFuture("waitNeighbours")
  let fut = result
  var neighbours = newSeqOfCap[Node](BUCKET_SIZE)
  k.neighboursCallbacks[remote] = proc(n: seq[Node]) {.gcsafe, raises: [].} =
    # This callback is expected to be called multiple times because nodes usually
    # split the neighbours replies into multiple packets, so we only complete the
    # future event.set() we've received enough neighbours.

    for i in n:
      if i != k.thisNode:
        neighbours.add(i)
        if neighbours.len == BUCKET_SIZE:
          k.neighboursCallbacks.del(remote)
          doAssert(not fut.finished)
          fut.complete(neighbours)

  onTimeout:
    if not fut.finished:
      k.neighboursCallbacks.del(remote)
      fut.complete(neighbours)

# Exported for test.
proc findNode*(k: KademliaProtocol, nodesSeen: ref HashSet[Node],
               nodeId: NodeId, remote: Node): Future[seq[Node]] {.async: (raises: [CancelledError]).} =
  if remote in k.neighboursCallbacks:
    # Sometimes findNode is called while another findNode is already in flight.
    # It's a bug when this happens, and the logic should probably be fixed
    # elsewhere.  However, this small fix has been tested and proven adequate.
    debug "Ignoring peer already in k.neighboursCallbacks", peer = remote
    result = newSeq[Node]()
    return
  k.wire.sendFindNode(remote, nodeId)
  var candidates = await k.waitNeighbours(remote)
  if candidates.len == 0:
    trace "Got no candidates from peer, returning", peer = remote
    result = candidates
  else:
    # The following line:
    # 1. Add new candidates to nodesSeen so that we don't attempt to bond with failing ones
    # in the future
    # 2. Removes all previously seen nodes from candidates
    # 3. Deduplicates candidates
    candidates.keepItIf(not nodesSeen[].containsOrIncl(it))
    trace "Got new candidates", count = candidates.len

    var bondedNodes: seq[Future[bool].Raising([CancelledError])] = @[]
    for node in candidates:
      if node != k.thisNode:
        bondedNodes.add(k.bond(node))

    await allFutures(bondedNodes)

    try:
      for i in 0..<bondedNodes.len:
        let b = bondedNodes[i]
        # `bond` will not raise so there should be no failures,
        # and for cancellation this should be fine to raise for now.
        doAssert(b.finished() and not(b.failed()))
        let bonded = b.read()
        if not bonded: candidates[i] = nil
    except FuturePendingError:
      raiseAssert "Future should be finished"

    candidates.keepItIf(not it.isNil)
    trace "Bonded with candidates", count = candidates.len
    result = candidates

proc populateNotFullBuckets(k: KademliaProtocol) =
  ## Go through all buckets that are not full and try to fill them.
  ##
  ## For every node in the replacement cache of every non-full bucket, try to bond.
  ## When the bonding succeeds the node is automatically added to the bucket.
  for bucket in k.routing.notFullBuckets:
    for node in bucket.replacementCache:
      asyncSpawn k.bondDiscard(node)

proc bond(k: KademliaProtocol, n: Node): Future[bool] {.async: (raises: [CancelledError]).} =
  ## Bond with the given node.
  ##
  ## Bonding consists of pinging the node, waiting for a pong and maybe a ping as well.
  ## It is necessary to do this at least once before we send findNode requests to a node.
  trace "Bonding to peer", n
  if n in k.routing:
    return true

  let pid = pingId(n, k.ping(n))
  if pid in k.pongFutures:
    debug "Bonding failed, already waiting for pong", n
    return false

  let gotPong = await k.waitPong(n, pid)
  if not gotPong:
    trace "Bonding failed, didn't receive pong from", n
    # Drop the failing node and schedule a populateNotFullBuckets() call to try and
    # fill its spot.
    k.routing.removeNode(n).expect("removeNode bucket exists")
    k.populateNotFullBuckets()
    return false

  # Give the remote node a chance to ping us before we move on and start sending findNode
  # requests. It is ok for waitPing() to timeout and return false here as that just means
  # the remote remembers us.
  if n in k.pingFutures:
    debug "Bonding failed, already waiting for ping", n
    return false

  discard await k.waitPing(n)

  trace "Bonding completed successfully", n
  k.updateRoutingTable(n).expect("updateRoutingTable bucket exists")
  true

proc bondDiscard(k: KademliaProtocol, n: Node):
       Future[void] {.async: (raises: [CancelledError]).} =
  discard await k.bond(n)

proc sortByDistance(nodes: var seq[Node], nodeId: NodeId, maxResults = 0) =
  nodes = nodes.sortedByIt(it.distanceTo(nodeId))
  if maxResults != 0 and nodes.len > maxResults:
    nodes.setLen(maxResults)

proc lookup*(k: KademliaProtocol, nodeId: NodeId): Future[seq[Node]] {.async: (raises: [CancelledError]).} =
  ## Lookup performs a network search for nodes close to the given target.

  ## It approaches the target by querying nodes that are closer to it on each iteration.  The
  ## given target does not need to be an actual node identifier.
  var nodesAsked = initHashSet[Node]()
  let nodesSeen = new(HashSet[Node])

  proc excludeIfAsked(nodes: seq[Node]): seq[Node] =
    result = toSeq(items(nodes.toHashSet() - nodesAsked))
    sortByDistance(result, nodeId, FIND_CONCURRENCY)

  var closest = k.routing.neighbours(nodeId)
  trace "Starting lookup; initial neighbours: ", closest
  var nodesToAsk = excludeIfAsked(closest)
  try:
    while nodesToAsk.len != 0:
      trace "Node lookup; querying ", nodesToAsk
      nodesAsked.incl(nodesToAsk.toHashSet())

      var findNodeRequests: seq[Future[seq[Node]].Raising([CancelledError])] = @[]
      for node in nodesToAsk:
        findNodeRequests.add(k.findNode(nodesSeen, nodeId, node))

      await allFutures(findNodeRequests)

      for candidates in findNodeRequests:
        # `findNode` will not raise so there should be no failures,
        # and for cancellation this should be fine to raise for now.
        doAssert(candidates.finished() and not(candidates.failed()))
        closest.add(candidates.read())

      sortByDistance(closest, nodeId, BUCKET_SIZE)
      nodesToAsk = excludeIfAsked(closest)
  except FuturePendingError:
    raiseAssert "Future should be finished"

  trace "Kademlia lookup finished", target = nodeId.toHex, closest
  result = closest

proc lookupRandom*(k: KademliaProtocol): Future[seq[Node]] {.async: (raises: [CancelledError]).} =
  await k.lookup(k.rng[].generate(NodeId))

proc resolve*(k: KademliaProtocol, id: NodeId): Future[Node] {.async: (raises: [CancelledError]).} =
  let closest = await k.lookup(id)
  for n in closest:
    if n.id == id: return n

proc bootstrap*(k: KademliaProtocol, bootstrapNodes: seq[Node], retries = 0) {.async: (raises: [CancelledError]).} =
  ## Bond with bootstrap nodes and do initial lookup. Retry `retries` times
  ## in case of failure, or indefinitely if `retries` is 0.
  if bootstrapNodes.len == 0:
    info "Skipping discovery bootstrap, no bootnodes provided"
    return

  var retryInterval = chronos.milliseconds(2)
  var numTries = 0

  try:
    while true:
      var bondedNodes: seq[Future[bool].Raising([CancelledError])] = @[]
      for node in bootstrapNodes:
        bondedNodes.add(k.bond(node))
      await allFutures(bondedNodes)

      # `bond` will not raise so there should be no failures,
      # and for cancellation this should be fine to raise for now.
      let bonded = bondedNodes.mapIt(it.read())

      if true notin bonded:
        inc numTries
        if retries == 0 or numTries < retries:
          info "Failed to bond with bootstrap nodes, retrying"
          retryInterval = min(chronos.seconds(10), retryInterval * 2)
          await sleepAsync(retryInterval)
        else:
          info "Failed to bond with bootstrap nodes"
          return
      else:
        break
      discard await k.lookupRandom() # Prepopulate the routing table
  except FuturePendingError:
    raiseAssert "Future should be finished"

proc recvPong*(k: KademliaProtocol, n: Node, token: seq[byte]) =
  trace "<<< pong from ", n
  let pingid = token & @(n.node.pubkey.toRaw)
  var future: Future[bool]
  if k.pongFutures.take(pingid, future):
    future.complete(true)
  k.updateLastPongReceived(n, getTime())

proc recvPing*(k: KademliaProtocol, n: Node, msgHash: auto): Result[void, cstring] =
  trace "<<< ping from ", n
  k.wire.sendPong(n, msgHash)

  if getTime() - k.lastPongReceived(n) > BOND_EXPIRATION:
    # TODO: It is strange that this would occur, as it means our own node would
    # have pinged us which should have caused an assert in the first place.
    if n != k.thisNode:
      let pingId = pingId(n, k.ping(n))

      var fut = k.pongFutures.getOrDefault(pingId)
      if fut.isNil:
        fut = k.waitPong(n, pingId)

      let cb = proc(data: pointer) {.gcsafe, raises: [].} =
                # fut.read == true if pingid exists
                try:
                  if fut.completed and fut.read:
                    k.updateRoutingTable(n).isOkOr:
                      error "recvPing: WaitPong exception", msg=error
                except CatchableError as exc:
                  error "recvPing: WaitPong exception", msg=exc.msg

      fut.addCallback cb
  else:
    ?k.updateRoutingTable(n)

  var future: Future[bool]
  if k.pingFutures.take(n, future):
    future.complete(true)
  k.updateLastPingReceived(n, getTime())
  ok()

proc recvNeighbours*(k: KademliaProtocol, remote: Node, neighbours: seq[Node]) =
  ## Process a neighbours response.
  ##
  ## Neighbours responses should only be received as a reply to a find_node, and that is only
  ## done as part of node lookup, so the actual processing is left to the callback from
  ## neighbours_callbacks, which is added (and removed after it's done or timed out) in
  ## wait_neighbours().
  trace "Received neighbours", remote, neighbours
  let cb = k.neighboursCallbacks.getOrDefault(remote)
  if not cb.isNil:
    cb(neighbours)
  else:
    trace "Unexpected neighbours, probably came too late", remote

proc recvFindNode*(k: KademliaProtocol, remote: Node, nodeId: NodeId): Result[void, cstring] =
  if remote notin k.routing:
    # FIXME: This is not correct; a node we've bonded before may have become unavailable
    # and thus removed from self.routing, but once it's back online we should accept
    # find_nodes from them.
    trace "Ignoring find_node request from unknown node ", remote
    return ok()
  ?k.updateRoutingTable(remote)
  var found = k.routing.neighbours(nodeId)
  found.sort() do(x, y: Node) -> int: cmp(x.id, y.id)
  k.wire.sendNeighbours(remote, found)
  ok()

proc randomNodes*(k: KademliaProtocol, count: int): seq[Node] =
  var count = count
  let sz = k.routing.len
  if count > sz:
    debug  "Looking for peers", requested = count, present = sz
    count = sz

  result = newSeqOfCap[Node](count)
  var seen = initHashSet[Node]()

  # This is a rather inefficient way of randomizing nodes from all buckets, but even if we
  # iterate over all nodes in the routing table, the time it takes would still be
  # insignificant compared to the time it takes for the network roundtrips when connecting
  # to nodes.
  while len(seen) < count:
    let bucket = k.rng[].sample(k.routing.buckets)
    if bucket.nodes.len != 0:
      let node = k.rng[].sample(bucket.nodes)
      if node notin seen:
        result.add(node)
        seen.incl(node)

proc nodesDiscovered*(k: KademliaProtocol): int = k.routing.len

when isMainModule:
  proc randomNode(): Node =
    newNode("enode://aa36fdf33dd030378a0168efe6ed7d5cc587fafa3cdd375854fe735a2e11ea3650ba29644e2db48368c46e1f60e716300ba49396cd63778bf8a818c09bded46f@13.93.211.84:30303")

  var nodes = @[randomNode()]
  doAssert(computeSharedPrefixBits(nodes) == ID_SIZE)
  nodes.add(randomNode())
  nodes[0].id = 0b1.u256
  nodes[1].id = 0b0.u256
  doAssert(computeSharedPrefixBits(nodes) == ID_SIZE - 1)

  nodes[0].id = 0b010.u256
  nodes[1].id = 0b110.u256
  doAssert(computeSharedPrefixBits(nodes) == ID_SIZE - 3)
