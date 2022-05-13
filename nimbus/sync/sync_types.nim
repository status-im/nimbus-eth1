# Nimbus - Types, data structures and shared utilities used in network sync
#
# Copyright (c) 2018-2021 Status Research & Development GmbH
# Licensed under either of
#  * Apache License, version 2.0, ([LICENSE-APACHE](LICENSE-APACHE) or
#    http://www.apache.org/licenses/LICENSE-2.0)
#  * MIT license ([LICENSE-MIT](LICENSE-MIT) or
#    http://opensource.org/licenses/MIT)
# at your option. This file may not be copied, modified, or
# distributed except according to those terms.

## Shared types, data structures and shared utilities used by the eth1
## network sync processes.

import
  std/options,
  stint, stew/byteutils, chronicles, chronos,
  eth/[common/eth_types, p2p]

type
  SnapSync* = ref object of RootObj
    ## Shared state among all peers of a syncing node.
    syncPeers*:             seq[SyncPeer]
    sharedFetch:            SharedFetchState        # Exported via templates.

  SyncPeer* = ref object
    ## Peer state tracking.
    ns*:                    SnapSync
    peer*:                  Peer                    # p2pProtocol(eth65).
    stopped*:               bool
    pendingGetBlockHeaders*:bool
    stats*:                 SyncPeerStats

    # Peer canonical chain head ("best block") search state.
    syncMode*:              SyncPeerMode
    bestBlockNumber*:       BlockNumber
    bestBlockHash*:         BlockHash
    huntLow*:               BlockNumber # Recent highest known present block.
    huntHigh*:              BlockNumber # Recent lowest known absent block.
    huntStep*:              typeof(BlocksRequest.skip)

    # State root to fetch state for.
    # This changes during sync and is slightly different for each peer.
    syncStateRoot*:         Option[TrieHash]

    nodeDataRequests:       NodeDataRequestQueue    # Exported via templates.
    fetch:                  FetchState              # Exported via templates.
    startedFetch*:          bool
    stopThisState*:         bool

  SyncPeerMode* = enum
    ## The current state of tracking the peer's canonical chain head.
    ## `bestBlockNumber` is only valid when this is `SyncLocked`.
    SyncLocked
    SyncOnlyHash
    SyncHuntForward
    SyncHuntBackward
    SyncHuntRange
    SyncHuntRangeFinal

  SyncPeerStats = object
    ## Statistics counters for events associated with this peer.
    ## These may be used to recognise errors and select good peers.
    ok*:                    SyncPeerStatsOk
    minor*:                 SyncPeerStatsMinor
    major*:                 SyncPeerStatsMajor

  SyncPeerStatsOk = object
    reorgDetected*:         Stat
    getBlockHeaders*:       Stat
    getNodeData*:           Stat

  SyncPeerStatsMinor = object
    timeoutBlockHeaders*:   Stat
    unexpectedBlockHash*:   Stat

  SyncPeerStatsMajor = object
    networkErrors*:         Stat
    excessBlockHeaders*:    Stat
    wrongBlockHeader*:      Stat

  Stat = distinct int

  BlockHash* = Hash256
    ## Hash of a block, goes with `BlockNumber`.

  TxHash* = Hash256
    ## Hash of a transaction.

  TrieHash* = Hash256
    ## Hash of a trie root: accounts, storage, receipts or transactions.

  NodeHash* = Hash256
    ## Hash of a trie node or other blob carried over `eth.NodeData`:
    ## account trie nodes, storage trie nodes, contract code.

  InteriorPath* = object
    ## Path to an interior node in an Ethereum hexary trie.  This is a sequence
    ## of 0 to 64 hex digits.  0 digits means the root node, and 64 digits
    ## means a leaf node whose path hasn't been converted to `LeafPath` yet.
    bytes: array[32, byte]  # Access with `path.digit(i)` instead.
    numDigits: byte         # Access with `path.depth` instead.

  LeafPath* = object
    ## Path to a leaf in an Ethereum hexary trie.  Individually, each leaf path
    ## is a hash, but rather than being the hash of the contents, it's the hash
    ## of the item's address.  Collectively, these hashes have some 256-bit
    ## numerical properties: ordering, intervals and meaningful difference.
    number: UInt256

  # Use `import snap/get_nodedata` to access the real type's methods.
  NodeDataRequestQueue {.inheritable, pure.} = ref object

  # Use `import snap/pie/trie_fetch` to access the real type's methods.
  SharedFetchState {.inheritable, pure.} = ref object

  # Use `import snap/pie/trie_fetch` to access the real type's methods.
  FetchState {.inheritable, pure.} = ref object

proc inc(stat: var Stat) {.borrow.}

template nodeDataRequestsBase*(sp: SyncPeer): auto =
  sp.nodeDataRequests
template `nodeDataRequests=`*(sp: SyncPeer, value: auto) =
  sp.nodeDataRequests = value

template sharedFetchBase*(sp: SyncPeer): auto =
  sp.ns.sharedFetch
template `sharedFetch=`*(sp: SyncPeer, value: auto) =
  sp.ns.sharedFetch = value

template fetchBase*(sp: SyncPeer): auto =
  sp.fetch
template `fetch=`*(sp: SyncPeer, value: auto) =
  sp.fetch = value

## `InteriorPath` methods.

template maxDepth*(_: InteriorPath | typedesc[InteriorPath]): int = 64

template rootInteriorPath*(): InteriorPath =
  # Initialised to empty sequence.
  InteriorPath()

template toInteriorPath*(interiorpath: InteriorPath): InteriorPath =
  interiorPath
template toInteriorPath*(leafPath: LeafPath): InteriorPath =
  doAssert sizeof(leafPath.number.toBytesBE) * 2 == InteriorPath.maxDepth
  doAssert sizeof(leafPath.number.toBytesBE) == sizeof(InteriorPath().bytes)
  InteriorPath(bytes: leafPath.number.toBytesBE,
               numDigits: InteriorPath.maxDepth)

template depth*(path: InteriorPath): int =
  path.numDigits.int

proc digit*(path: InteriorPath, index: int): int =
  doAssert index >= 0 and index < path.numDigits.int
  let b = path.bytes[index shr 1]
  (if (index and 1) == 0: (b shr 4) else: (b and 0x0f)).int

proc add*(path: var InteriorPath, digit: byte) =
  doAssert path.numDigits < InteriorPath.maxDepth
  inc path.numDigits
  if (path.numDigits and 1) != 0:
    path.bytes[path.numDigits shr 1] = (digit shl 4)
  else:
    path.bytes[(path.numDigits shr 1) - 1] += (digit and 0x0f)

proc addPair*(path: var InteriorPath, digitPair: byte) =
  doAssert path.numDigits < InteriorPath.maxDepth - 1
  path.numDigits += 2
  if (path.numDigits and 1) == 0:
    path.bytes[(path.numDigits shr 1) - 1] = digitPair
  else:
    path.bytes[(path.numDigits shr 1) - 1] += (digitPair shr 4)
    path.bytes[path.numDigits shr 1] = (digitPair shl 4)

proc pop*(path: var InteriorPath) =
  doAssert path.numDigits >= 1
  dec path.numDigits
  path.bytes[path.numDigits shr 1] =
    if (path.numDigits and 1) == 0: 0.byte
    else: path.bytes[path.numDigits shr 1] and 0xf0

proc `==`*(path1, path2: InteriorPath): bool =
  # Paths are zero-padded to the end of the array, so comparison is easy.
  for i in 0 ..< (max(path1.numDigits, path2.numDigits).int + 1) shr 1:
    if path1.bytes[i] != path2.bytes[i]:
      return false
  return true

proc `<=`*(path1, path2: InteriorPath): bool =
  # Paths are zero-padded to the end of the array, so comparison is easy.
  for i in 0 ..< (max(path1.numDigits, path2.numDigits).int + 1) shr 1:
    if path1.bytes[i] != path2.bytes[i]:
      return path1.bytes[i] <= path2.bytes[i]
  return true

proc cmp*(path1, path2: InteriorPath): int =
  # Paths are zero-padded to the end of the array, so comparison is easy.
  for i in 0 ..< (max(path1.numDigits, path2.numDigits).int + 1) shr 1:
    if path1.bytes[i] != path2.bytes[i]:
      return path1.bytes[i].int - path2.bytes[i].int
  return 0

template `!=`*(path1, path2: InteriorPath): auto = not(path1 == path2)
template `<`*(path1, path2: InteriorPath): auto = not(path2 <= path1)
template `>=`*(path1, path2: InteriorPath): auto = path2 <= path1
template `>`*(path1, path2: InteriorPath): auto = not(path1 <= path2)

## `LeafPath` methods.

template low*(_: LeafPath | type LeafPath): auto =
  LeafPath(number: low(UInt256))
template high*(_: LeafPath | type LeafPath): auto =
  LeafPath(number: high(UInt256))

const leafPathBytes = sizeof(LeafPath().number.toBytesBE)

template toLeafPath*(leafPath: LeafPath): LeafPath =
  leafPath
template toLeafPath*(interiorPath: InteriorPath): LeafPath =
  doAssert interiorPath.numDigits == InteriorPath.maxDepth
  doAssert sizeof(interiorPath.bytes) * 2 == InteriorPath.maxDepth
  doAssert sizeof(interiorPath.bytes) == leafPathBytes
  LeafPath(number: UInt256.fromBytesBE(interiorPath.bytes))
template toLeafPath*(bytes: array[leafPathBytes, byte]): LeafPath =
  doAssert sizeof(bytes) == leafPathBytes
  LeafPath(number: UInt256.fromBytesBE(bytes))

template toBytes*(leafPath: LeafPath): array[leafPathBytes, byte] =
  doAssert sizeof(LeafPath().number.toBytesBE) == leafPathBytes
  leafPath.number.toBytesBE

# Note, `{.borrow.}` didn't work for these symbols (with Nim 1.2.12) when we
# defined `LeafPath = distinct UInt256`.  The `==` didn't match any symbol to
# borrow from, and the auto-generated `<` failed to compile, with a peculiar
# type mismatch error.
template `==`*(path1, path2: LeafPath): auto = path1.number == path2.number
template `!=`*(path1, path2: LeafPath): auto = path1.number != path2.number
template `<`*(path1, path2: LeafPath): auto = path1.number < path2.number
template `<=`*(path1, path2: LeafPath): auto = path1.number <= path2.number
template `>`*(path1, path2: LeafPath): auto = path1.number > path2.number
template `>=`*(path1, path2: LeafPath): auto = path1.number >= path2.number
template cmp*(path1, path2: LeafPath): auto = cmp(path1.number, path2.number)

template `-`*(path1, path2: LeafPath): UInt256 =
  path1.number - path2.number
template `+`*(base: LeafPath, step: Uint256 | SomeInteger): LeafPath =
  LeafPath(number: base.number + step)
template `-`*(base: LeafPath, step: Uint256 | SomeInteger): LeafPath =
  LeafPath(number: base.number - step)

## String output functions.

template `$`*(sp: SyncPeer): string = $sp.peer
template `$`*(hash: Hash256): string = hash.data.toHex
template `$`*(blob: Blob): string = blob.toHex
template `$`*(hashOrNum: HashOrNum): string =
  # It's always obvious which one from the visible length of the string.
  if hashOrNum.isHash: $hashOrNum.hash
  else: $hashOrNum.number

proc toHex*(path: InteriorPath, withEllipsis = true): string =
  const hexChars = "0123456789abcdef"
  let digits = path.numDigits.int
  if not withEllipsis:
    result = newString(digits)
  else:
    result = newString(min(digits + 3, 64))
    result[^3] = '.'
    result[^2] = '.'
    result[^1] = '.'
  for i in 0 ..< digits:
    result[i] = hexChars[path.digit(i)]

template `$`*(path: InteriorPath): string = path.toHex
proc pathRange*(path1, path2: InteriorPath): string =
  path1.toHex(false) & '-' & path2.toHex(false)

template toHex*(path: LeafPath): string = path.number.toBytesBE.toHex
template `$`*(path: LeafPath): string = path.toHex
proc pathRange*(path1, path2: LeafPath): string =
  path1.toHex & '-' & path2.toHex

export Blob, Hash256, toHex

# The files and lines clutter more useful details when sync tracing is enabled.
publicLogScope: chroniclesLineNumbers=false

# Use `safeSetTimer` consistently, with a `ref T` argument if including one.
type
  SafeCallbackFunc*[T] = proc (objectRef: ref T) {.gcsafe, raises: [Defect].}
  SafeCallbackFuncVoid* = proc () {.gcsafe, raises: [Defect].}

proc safeSetTimer*[T](at: Moment, cb: SafeCallbackFunc[T],
                      objectRef: ref T = nil): TimerCallback =
  ## Like `setTimer` but takes a typed `ref T` argument, which is passed to the
  ## callback function correctly typed.  Stores the `ref` in a closure to avoid
  ## garbage collection memory corruption issues that occur when the `setTimer`
  ## pointer argument is used.
  proc chronosTimerSafeCb(udata: pointer) = cb(objectRef)
  return setTimer(at, chronosTimerSafeCb)

proc safeSetTimer*[T](at: Moment, cb: SafeCallbackFuncVoid): TimerCallback =
  ## Like `setTimer` but takes no pointer argument.  The callback function
  ## takes no arguments.
  proc chronosTimerSafeCb(udata: pointer) = cb()
  return setTimer(at, chronosTimerSafeCb)

proc setTimer*(at: Moment, cb: CallbackFunc, udata: pointer): TimerCallback
  {.error: "Do not use setTimer with a `pointer` type argument".}
  ## `setTimer` with a non-nil pointer argument is dangerous because
  ## the pointed-to object is often freed or garbage collected before the
  ## timer callback runs.  Call `setTimer` with a `ref` argument instead.

proc setTimer*(at: Moment, cb: CallbackFunc): TimerCallback =
  chronos.setTimer(at, cb, nil)
