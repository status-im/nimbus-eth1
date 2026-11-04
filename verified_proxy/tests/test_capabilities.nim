# nimbus_verified_proxy
# Copyright (c) 2026 Status Research & Development GmbH
# Licensed and distributed under either of
#   * MIT license (license terms in the root directory or at https://opensource.org/licenses/MIT).
#   * Apache v2 license (license terms in the root directory or at https://www.apache.org/licenses/LICENSE-2.0).
# at your option. This file may not be copied, modified, or distributed except according to those terms.

{.used.}
{.push raises: [].}

import
  unittest2,
  stint,
  results,
  chronos,
  web3/[eth_api, eth_api_types],
  eth/common/[base, times, eth_types_rlp],
  ../engine/engine,
  ../engine/header_store,
  ../engine/types,
  ./test_api_backend

const FORK_TIME = 1_746_612_311'u64 # mainnet Prague, arbitrary reference point

proc newEngine(): RpcVerificationEngine =
  RpcVerificationEngine
    .initCore(
      chainId = 1.u256,
      networkId = 1.u256,
      maxBlockWalk = 1000,
      maxWindowJumps = 500,
      parallelBlockDownloads = 1,
      headerStoreLen = 16,
      accountCacheLen = 1,
      codeCacheLen = 1,
      storageCacheLen = 1,
    )
    .expect("initCore should succeed")

proc addHeader(engine: RpcVerificationEngine, number: uint64, timestamp: uint64) =
  let header = Header(number: base.BlockNumber(number), timestamp: EthTime(timestamp))
  engine.headerStore.put(header, header.computeBlockHash, Finalized)
  engine.headerStore.putHash(header.computeBlockHash, Optimistic)
  engine.headerStore.putHash(header.computeBlockHash, Finalized)

proc earliest(engine: RpcVerificationEngine): Opt[Hash32] =
  engine.headerStore.getEarliestHash()

suite "archive backend capability routing":
  let
    generalCaps = fullExecutionCapabilities - {GetProof}
    ts = TestApiState.init(1.u256)

  test "GetProof only ever routes to the archive backend":
    let engine = newEngine()
    engine.registerBackend(initTestExecutionBackend(ts), generalCaps) # idx 0
    engine.registerBackend(initTestExecutionBackend(ts), {GetProof}) # idx 1

    let (_, idx) = engine.executionBackendFor(GetProof).expect("archive present")
    check idx == 1

  test "non-state methods never route to the archive-only backend":
    let engine = newEngine()
    engine.registerBackend(initTestExecutionBackend(ts), generalCaps) # idx 0
    engine.registerBackend(initTestExecutionBackend(ts), {GetProof}) # idx 1

    let (_, idx) =
      engine.executionBackendFor(GetBlockByNumber).expect("general present")
    check idx == 0

  test "without an archive backend GetProof still routes to the general backend":
    let engine = newEngine()
    engine.registerBackend(initTestExecutionBackend(ts), fullExecutionCapabilities)

    let (_, idx) = engine.executionBackendFor(GetProof).expect("general present")
    check idx == 0

suite "private transaction backend capability routing":
  let
    generalCaps = fullExecutionCapabilities - {SendRawTransaction}
    ts = TestApiState.init(1.u256)

  test "SendRawTransaction only ever routes to the private tx backend":
    let engine = newEngine()
    engine.registerBackend(initTestExecutionBackend(ts), generalCaps) # idx 0
    engine.registerBackend(initTestExecutionBackend(ts), {SendRawTransaction}) # idx 1

    let (_, idx) =
      engine.executionBackendFor(SendRawTransaction).expect("private relay present")
    check idx == 1

  test "read methods never route to the private-tx-only backend":
    let engine = newEngine()
    engine.registerBackend(initTestExecutionBackend(ts), generalCaps) # idx 0
    engine.registerBackend(initTestExecutionBackend(ts), {SendRawTransaction}) # idx 1

    let (_, idx) =
      engine.executionBackendFor(GetBlockByNumber).expect("general present")
    check idx == 0

  test "without a private relay SendRawTransaction still routes to the general backend":
    let engine = newEngine()
    engine.registerBackend(initTestExecutionBackend(ts), fullExecutionCapabilities)

    let (_, idx) =
      engine.executionBackendFor(SendRawTransaction).expect("general present")
    check idx == 0

suite "earliest anchor":
  const head = 10_000_000'u64

  test "the first finalized anchor becomes the earliest":
    let engine = newEngine()
    engine.addHeader(head - 50, FORK_TIME + 100)

    check engine.earliest() == engine.headerStore.getHash(Finalized)

  test "later finalized anchors don't move the earliest":
    let engine = newEngine()
    engine.addHeader(head - 50, FORK_TIME + 100)

    let first = engine.earliest()

    engine.addHeader(head, FORK_TIME + 200)

    check:
      engine.earliest() == first
      engine.headerStore.getHash(Finalized) != first

  test "an optimistic anchor alone leaves the earliest unset":
    let engine = newEngine()
    let header = Header(number: base.BlockNumber(head), timestamp: EthTime(FORK_TIME))

    engine.headerStore.put(header, header.computeBlockHash, Optimistic)
    engine.headerStore.putHash(header.computeBlockHash, Optimistic)

    check engine.earliest().isNone()

  test "clear drops the earliest anchor":
    let engine = newEngine()
    engine.addHeader(head, FORK_TIME + 100)

    engine.headerStore.clear()

    check engine.earliest().isNone()
