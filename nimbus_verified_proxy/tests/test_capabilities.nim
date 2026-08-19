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
  web3/[eth_api, eth_api_types],
  eth/common/[base, times, eth_types_rlp],
  ../engine/blocks,
  ../engine/engine,
  ../engine/header_store,
  ../engine/types,
  ./test_api_backend

const
  WINDOW_JUMP = 8190'u64 # HISTORY_SERVE_WINDOW - 1, mirrors blocks.nim
  FORK_TIME = 1_746_612_311'u64 # mainnet Prague, arbitrary reference point

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
  discard engine.headerStore.add(header, header.computeBlockHash)

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

suite "earliest servable block":
  const head = 10_000_000'u64

  test "no fork time configured falls back to header store earliest":
    let engine = newEngine()
    engine.eip2935ForkTime = Opt.none(EthTime)
    engine.addHeader(head - 50, FORK_TIME + 100)
    engine.addHeader(head, FORK_TIME + 200)

    check engine.earliestServableBlock().expect("has headers") ==
      base.BlockNumber(head - 50)

  test "head older than fork time falls back to header store earliest":
    let engine = newEngine()
    engine.eip2935ForkTime = Opt.some(EthTime(FORK_TIME))
    engine.addHeader(head - 50, FORK_TIME - 200)
    engine.addHeader(head, FORK_TIME - 100)

    check engine.earliestServableBlock().expect("has headers") ==
      base.BlockNumber(head - 50)

  test "post-fork without archive reaches back exactly one window":
    let engine = newEngine()
    engine.eip2935ForkTime = Opt.some(EthTime(FORK_TIME))
    engine.state = EngineState(archive: false)
    engine.addHeader(head, FORK_TIME + 100)

    check engine.earliestServableBlock().expect("has latest") ==
      base.BlockNumber(head - WINDOW_JUMP)

  test "post-fork with archive reaches back maxWindowJumps windows":
    let engine = newEngine()
    engine.eip2935ForkTime = Opt.some(EthTime(FORK_TIME))
    engine.state = EngineState(archive: true)
    engine.addHeader(head, FORK_TIME + 100)

    check engine.earliestServableBlock().expect("has latest") ==
      base.BlockNumber(head - WINDOW_JUMP * engine.maxWindowJumps)

  test "chain shorter than the reach clamps to zero instead of underflowing":
    let engine = newEngine()
    engine.eip2935ForkTime = Opt.some(EthTime(FORK_TIME))
    engine.state = EngineState(archive: true)
    engine.addHeader(5000, FORK_TIME + 100)

    check engine.earliestServableBlock().expect("has latest") == base.BlockNumber(0)

  test "no latest header yields an error":
    let engine = newEngine()
    engine.eip2935ForkTime = Opt.some(EthTime(FORK_TIME))
    check engine.earliestServableBlock().isErr()
