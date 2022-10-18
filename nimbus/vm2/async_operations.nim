# Nimbus
# Copyright (c) 2022 Status Research & Development GmbH
# Licensed under either of
#  * Apache License, version 2.0, ([LICENSE-APACHE](LICENSE-APACHE) or
#    http://www.apache.org/licenses/LICENSE-2.0)
#  * MIT license ([LICENSE-MIT](LICENSE-MIT) or
#    http://opensource.org/licenses/MIT)
# at your option. This file may not be copied, modified, or distributed except
# according to those terms.

import
  chronos,
  stint,
  json_rpc/rpcclient,
  web3,
  ./computation,
  ./state,
  ./types,
  ../vm_async,
  ../db/accounts_cache

method ifNecessaryFetchStorageSlot*(f: LazyDataSource, c: Computation, slot: UInt256): Future[void] {.base.} =
  quit "must override"

method ifNecessaryFetchStorageSlot*(f: RealLazyDataSource, c: Computation, slot: UInt256): Future[void] {.async.} =
  if c.hasStorage(slot): return  # already have it, no need to fetch

  # FIXME-onDemandStorageNotImplementedYet
  # (I sketched in this code, but haven't actually tried running it yet.)
  echo("Attempting to for-real fetch slot " & $(slot))
  # ethAddressStr("0xfff33a3bd36abdbd412707b8e310d6011454a7ae")
  # check hexDataStr(0.u256).string == res.string
  let ethAddress = c.msg.contractAddress
  let address: Address = Address(ethAddress)
  let quantity: int = slot.truncate(int)  # this is probably wrong; what's the right way to convert this?
  let blockId: BlockIdentifier = blockId(c.vmState.parent.blockNumber.truncate(uint64)) # ditto
  let res = await f.client.eth_getStorageAt(address, quantity, blockId)
  echo("Fetched slot " & $(slot) & ", result is " & $(res))
  let v = res  # will res be the actual value, or do I need to convert or something?
  c.vmState.mutateStateDB:
    db.setStorage(c.msg.contractAddress, slot, UInt256.fromBytesBE(v))

method ifNecessaryFetchStorageSlot*(f: FakeLazyDataSource, c: Computation, slot: UInt256): Future[void] {.async.} =
  if c.hasStorage(slot): return  # already have it, no need to fetch

  # FIXME-writeAutomatedTestsToShowThatItCanRunConcurrently

  # For now, until I've implemented some more automated way to
  # capture and verify the fact that this can run concurrently,
  # this is useful just to see in the console that the echo
  # statements from multiple Computations can run at the same
  # time and be interleaved.
  # echo("Attempting to fake-fetch slot " & $(slot))
  # await sleepAsync(2.seconds)  

  let slotBytes = toBytesBE(slot)
  # The linear search is obviously slow, but doesn't matter
  # for tests with only a few initialStorage entries. Fix
  # this if we ever want to write tests with more.
  for (k, v) in f.fakePairs:
    if slotBytes == k:
      c.vmState.mutateStateDB:
        db.setStorage(c.msg.contractAddress, slot, UInt256.fromBytesBE(v))
      break

  # echo("Finished fake-fetch of slot " & $(slot))
    

method ifNecessaryFetchStorageSlot*(f: NoLazyDataSource, c: Computation, slot: UInt256): Future[void] {.async.} =
  # FIXME-areAsyncOperationsNecessaryDuringSynchronousExecution 
  discard



# Gotta find the place where we're creating a Computation without setting
# its asyncFactory in the first place, but this is fine for now.
proc asyncFactory*(c: Computation): AsyncOperationFactory =
  # Does Nim have an "ifNil" macro/template?
  if isNil(c.vmState.asyncFactory):
    AsyncOperationFactory(lazyDataSource: NoLazyDataSource())
  else:
    c.vmState.asyncFactory

proc runAsyncOperation*(c: Computation, o: Vm2AsyncOperation): Future[void] =
  let lds = asyncFactory(c).lazyDataSource
  case o.kind:
  of aokGetStorage:
    return ifNecessaryFetchStorageSlot(lds, c, o.slot)
