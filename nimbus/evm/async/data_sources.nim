# Nimbus
# Copyright (c) 2023-2024 Status Research & Development GmbH
# Licensed under either of
#  * Apache License, version 2.0, ([LICENSE-APACHE](LICENSE-APACHE) or
#    http://www.apache.org/licenses/LICENSE-2.0)
#  * MIT license ([LICENSE-MIT](LICENSE-MIT) or
#    http://opensource.org/licenses/MIT)
# at your option. This file may not be copied, modified, or distributed except
# according to those terms.

import
  std/options,
  chronos,
  stint,
  eth/common,
  ../../db/core_db

type
  AsyncDataSource* = ref object of RootObj
    ifNecessaryGetSlots*:       proc(db: CoreDbRef, blockNumber: BlockNumber, stateRoot: Hash256, address: EthAddress, slots: seq[UInt256], newStateRootForSanityChecking: Hash256): Future[void] {.gcsafe.}
    ifNecessaryGetCode*:        proc(db: CoreDbRef, blockNumber: BlockNumber, stateRoot: Hash256, address: EthAddress, newStateRootForSanityChecking: Hash256): Future[void] {.gcsafe.}
    ifNecessaryGetAccount*:     proc(db: CoreDbRef, blockNumber: BlockNumber, stateRoot: Hash256, address: EthAddress, newStateRootForSanityChecking: Hash256): Future[void] {.gcsafe.}
    ifNecessaryGetBlockHeaderByNumber*: proc(coreDb: CoreDbRef, blockNumber: BlockNumber): Future[void] {.gcsafe.}
    # FIXME-Adam: Later.
    #fetchNodes*: proc(stateRoot: Hash256, paths: seq[seq[seq[byte]]], nodeHashes: seq[Hash256]): Future[seq[seq[byte]]] {.gcsafe.}
    fetchBlockHeaderWithHash*: proc(h: Hash256): Future[BlockHeader] {.gcsafe.}
    fetchBlockHeaderWithNumber*: proc(n: BlockNumber): Future[BlockHeader] {.gcsafe.}
    fetchBlockHeaderAndBodyWithHash*: proc(h: Hash256): Future[(BlockHeader, BlockBody)] {.gcsafe.}
    fetchBlockHeaderAndBodyWithNumber*: proc(n: BlockNumber): Future[(BlockHeader, BlockBody)] {.gcsafe.}

  # FIXME-Adam: maybe rename this?
  AsyncOperationFactory* = ref object of RootObj
    maybeDataSource*: Option[AsyncDataSource]


# FIXME-Adam: Can I make a singleton?
proc asyncFactoryWithNoDataSource*(): AsyncOperationFactory =
  AsyncOperationFactory(maybeDataSource: none[AsyncDataSource]())


# FIXME-Adam: Ugly but straightforward; can this be cleaned up using some combination of:
#   - an ifSome/map operation on Options
#   - some kind of "what are we fetching" tuple, so that this is just one thing

proc ifNecessaryGetSlots*(asyncFactory: AsyncOperationFactory, db: CoreDbRef, blockNumber: BlockNumber, stateRoot: Hash256, address: EthAddress, slots: seq[UInt256], newStateRootForSanityChecking: Hash256): Future[void] {.async.} =
  #if asyncFactory.maybeDataSource.isSome:
  #  await asyncFactory.maybeDataSource.get.ifNecessaryGetSlots(db, blockNumber, stateRoot, address, slots, newStateRootForSanityChecking)
  discard

proc ifNecessaryGetCode*(asyncFactory: AsyncOperationFactory, db: CoreDbRef, blockNumber: BlockNumber, stateRoot: Hash256, address: EthAddress, newStateRootForSanityChecking: Hash256): Future[void] {.async.} =
  #if asyncFactory.maybeDataSource.isSome:
  #  await asyncFactory.maybeDataSource.get.ifNecessaryGetCode(db, blockNumber, stateRoot, address, newStateRootForSanityChecking)
  discard

proc ifNecessaryGetAccount*(asyncFactory: AsyncOperationFactory, db: CoreDbRef, blockNumber: BlockNumber, stateRoot: Hash256, address: EthAddress, newStateRootForSanityChecking: Hash256): Future[void] {.async.} =
  #if asyncFactory.maybeDataSource.isSome:
  #  await asyncFactory.maybeDataSource.get.ifNecessaryGetAccount(db, blockNumber, stateRoot, address, newStateRootForSanityChecking)
  discard

proc ifNecessaryGetBlockHeaderByNumber*(asyncFactory: AsyncOperationFactory, coreDb: CoreDbRef, blockNumber: BlockNumber): Future[void] {.async.} =
  #if asyncFactory.maybeDataSource.isSome:
  #  await asyncFactory.maybeDataSource.get.ifNecessaryGetBlockHeaderByNumber(coreDb, blockNumber)
  discard
