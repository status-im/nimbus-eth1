# Nimbus
# Copyright (c) 2023 Status Research & Development GmbH
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
  eth/common,
  ../../common as dot_common,
  ../../db/ledger,
  ../types,
  ./data_sources



proc ifNecessaryGetAccount*(vmState: BaseVMState, address: EthAddress): Future[void] {.async.} =
  if vmState.com.db.localDbOnly: return
  await vmState.asyncFactory.ifNecessaryGetAccount(vmState.com.db, vmState.parent.blockNumber, vmState.parent.stateRoot, address, vmState.stateDB.rawRootHash)

proc ifNecessaryGetCode*(vmState: BaseVMState, address: EthAddress): Future[void] {.async.} =
  if vmState.com.db.localDbOnly: return
  await vmState.asyncFactory.ifNecessaryGetCode(vmState.com.db, vmState.parent.blockNumber, vmState.parent.stateRoot, address, vmState.stateDB.rawRootHash)

proc ifNecessaryGetSlots*(vmState: BaseVMState, address: EthAddress, slots: seq[UInt256]): Future[void] {.async.} =
  if vmState.com.db.localDbOnly: return
  await vmState.asyncFactory.ifNecessaryGetSlots(vmState.com.db, vmState.parent.blockNumber, vmState.parent.stateRoot, address, slots, vmState.stateDB.rawRootHash)

proc ifNecessaryGetSlot*(vmState: BaseVMState, address: EthAddress, slot: UInt256): Future[void] {.async.} =
  if vmState.com.db.localDbOnly: return
  await ifNecessaryGetSlots(vmState, address, @[slot])

proc ifNecessaryGetBlockHeaderByNumber*(vmState: BaseVMState, blockNumber: BlockNumber): Future[void] {.async.} =
  if vmState.com.db.localDbOnly: return
  await vmState.asyncFactory.ifNecessaryGetBlockHeaderByNumber(vmState.com.db, blockNumber)

#[
FIXME-Adam: This is for later.
proc fetchAndPopulateNodes*(vmState: BaseVMState, paths: seq[seq[seq[byte]]], nodeHashes: seq[Hash256]): Future[void] {.async.} =
  if vmState.asyncFactory.maybeDataSource.isSome:
    # let stateRoot = vmState.stateDB.rawRootHash # FIXME-Adam: this might not be right, huh? the peer might expect the parent block's final stateRoot, not this weirdo intermediate one
    let stateRoot = vmState.parent.stateRoot
    let nodes = await vmState.asyncFactory.maybeDataSource.get.fetchNodes(stateRoot, paths, nodeHashes)
    populateDbWithNodes(vmState.stateDB.rawDb, nodes)
]#


# Sometimes it's convenient to be able to do multiple at once.

proc ifNecessaryGetAccounts*(vmState: BaseVMState, addresses: seq[EthAddress]): Future[void] {.async.} =
  if vmState.com.db.localDbOnly: return
  for address in addresses:
    await ifNecessaryGetAccount(vmState, address)

proc ifNecessaryGetCodeForAccounts*(vmState: BaseVMState, addresses: seq[EthAddress]): Future[void] {.async.} =
  if vmState.com.db.localDbOnly: return
  for address in addresses:
    await ifNecessaryGetCode(vmState, address)
