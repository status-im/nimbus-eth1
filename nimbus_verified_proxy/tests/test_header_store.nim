# Nimbus
# Copyright (c) 2025 Status Research & Development GmbH
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
  beacon_chain/spec/helpers

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

suite "test proxy header store":
  test "get from empty store":
    let store = HeaderStore.new(1)
    check store.get(default(Hash32)).isNone()
    check store.get(default(BlockNumber)).isNone()
    check store.latest.isNone()
    check store.latestHash.isNone()
    check store.len == 0
    check store.isEmpty()

  test "get from a non-pruned semi-filled store":
    let store = HeaderStore.new(10)
    for i in 0 ..< 5:
      discard store.add(headerGenerator(i))

    check store.len == 5
    check store.get(BlockNumber(0)).isSome()
    check store.latest.isSome()
    check store.latest.get().number == 4
    check store.latestHash.isSome()
    check (not store.isEmpty())

  test "header store auto pruning":
    let store = HeaderStore.new(10)
    for i in 0 ..< 10:
      discard store.add(headerGenerator(i))

    check store.get(BlockNumber(0)).isSome()

    discard store.add(headerGenerator(10))

    check store.latest.isSome()
    check store.latest.get().number == 10
    check store.get(BlockNumber(0)).isNone()

  test "duplicate addition should not work":
    let store = HeaderStore.new(10)
    for i in 0 ..< 11:
      discard store.add(headerGenerator(i))

    discard store.add(headerGenerator(10))

    check store.latest.isSome()
    check store.latest.get.number == 10
    check store.get(BlockNumber(1)).isSome()

    discard store.add(headerGenerator(11))

    check store.latest.isSome()
    check store.latest.get.number == 11
    check store.get(BlockNumber(1)).isNone()

  test "update finalized":
    let store = HeaderStore.new(10)
    for i in 0 ..< 10:
      discard store.add(headerGenerator(i))

    discard store.updateFinalized(headerGenerator(0))

    check store.len == 10
    check store.get(BlockNumber(0)).isSome()
    check store.finalized.isSome()
    check store.finalizedHash.isSome()
    check store.earliest.isSome()
    check store.earliestHash.isSome()
    check store.earliestHash.get() == store.finalizedHash.get()
    check store.earliest.get() == store.finalized.get()

    discard store.updateFinalized(headerGenerator(1))

    check store.earliest.get() != store.finalized.get()
    check store.earliestHash.get() != store.finalizedHash.get()
    check store.finalized.get().number == 1

  test "add altair header":
    let store = HeaderStore.new(5)
    let altairHeader = ForkedLightClientHeader(
      kind: LightClientDataFork.Altair,
      altairData: altair.LightClientHeader(beacon: default(altair.BeaconBlockHeader)),
    )
    let res = store.add(altairHeader)

    check res.isErr()

  test "add electra header":
    let store = HeaderStore.new(5)
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
