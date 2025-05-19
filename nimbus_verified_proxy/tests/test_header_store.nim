# eth
# Copyright (c) 2019-2025 Status Research & Development GmbH
# Licensed and distributed under either of
#   * MIT license (license terms in the root directory or at https://opensource.org/licenses/MIT).
#   * Apache v2 license (license terms in the root directory or at https://www.apache.org/licenses/LICENSE-2.0).
# at your option. This file may not be copied, modified, or distributed except according to those terms.

{.used.}

import
  unittest2,
  stint/endians2,
  eth/common/headers_rlp,
  ../header_store,
  beacon_chain/spec/forks,
  beacon_chain/spec/helpers,
  beacon_chain/el/engine_api_conversions

func headerGenerator(number: int): ForkedLightClientHeader =
  ForkedLightClientHeader(
    kind: LightClientDataFork.Capella,
    capellaData: capella.LightClientHeader(
      beacon: default(capella.BeaconBlockHeader),
      execution: capella.ExecutionPayloadHeader(
        block_number: uint64(number), block_hash: Hash32(toBytesBE(u256(number)))
      ),
      execution_branch: default(capella.ExecutionBranch),
    ),
  )

let store = HeaderStore.new(64)

suite "test proxy header store":
  test "get from empty store":
    check store.get(default(Hash32)).isNone()
    check store.get(default(BlockNumber)).isNone()
    check store.latest.isNone()
    check store.latestHash.isNone()
    check store.earliest.isNone()
    check store.earliestHash.isNone()
    check store.len == 0
    check store.isEmpty()

  test "add one item only":
    discard store.add(headerGenerator(0))
    let
      latestHeader = store.latest
      earliestHeader = store.earliest
      latestHash = store.latestHash
      earliestHash = store.earliestHash

    check latestHeader.isSome()
    check earliestHeader.isSome()
    check latestHeader.get() == earliestHeader.get()
    check latestHash.isSome()
    check earliestHash.isSome()
    check latestHash.get() == earliestHash.get()

  test "get from a non-pruned semi-filled store":
    for i in 0 ..< 32:
      discard store.add(headerGenerator(i))

    check store.len == 32

    let h = store.get(BlockNumber(0))

    check h.isSome()
    check store.latest.isSome()
    check store.latest.get().number == 31
    check store.latestHash.isSome()
    check store.earliest.isSome()
    check store.earliest.get().number == 0
    check store.earliestHash.isSome()
    check (not store.isEmpty())

  test "header store auto pruning":
    for i in 32 ..< 64:
      discard store.add(headerGenerator(i))

    let h = store.earliest

    check h.isSome()
    check h.get.number == 0

    discard store.add(headerGenerator(64))

    check store.earliest.isSome()
    check store.earliest.get().number == 1
    check store.latest.isSome()
    check store.latest.get().number == 64
    check store.get(BlockNumber(0)).isNone()

  test "duplicate addition should not work":
    discard store.add(headerGenerator(64))

    check store.earliest.isSome()
    check store.earliest.get().number == 1
    check store.latest.isSome()
    check store.latest.get.number == 64
    check store.get(BlockNumber(0)).isNone()

    discard store.add(headerGenerator(65))

    check store.earliest.isSome()
    check store.earliest.get().number == 2
    check store.latest.isSome()
    check store.latest.get.number == 65
    check store.get(BlockNumber(1)).isNone()

  test "add altair header":
    let altairHeader = ForkedLightClientHeader(
      kind: LightClientDataFork.Altair,
      altairData: altair.LightClientHeader(beacon: default(altair.BeaconBlockHeader)),
    )
    let res = store.add(altairHeader)

    check res.isErr()

  test "add electra header":
    let electraHeader = ForkedLightClientHeader(
      kind: LightClientDataFork.Electra,
      electraData: electra.LightClientHeader(
        beacon: default(electra.BeaconBlockHeader),
        execution: electra.ExecutionPayloadHeader(block_number: uint64(232)),
        execution_branch: default(capella.ExecutionBranch),
      ),
    )
    let res = store.add(electraHeader)

    check res.isOk()
