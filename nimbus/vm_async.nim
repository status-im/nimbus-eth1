# Nimbus
# Copyright (c) 2022 Status Research & Development GmbH
# Licensed under either of
#  * Apache License, version 2.0, ([LICENSE-APACHE](LICENSE-APACHE) or http://www.apache.org/licenses/LICENSE-2.0)
#  * MIT license ([LICENSE-MIT](LICENSE-MIT) or http://opensource.org/licenses/MIT)
# at your option. This file may not be copied, modified, or distributed except according to those terms.



import
  chronos,
  stint,
  json_rpc/rpcclient

type
  # Only one kind for now, but in the future we may have more.
  Vm2AsyncOperationKind* = enum
    aokGetStorage
  Vm2AsyncOperation* = ref object
    case kind*: Vm2AsyncOperationKind
    of aokGetStorage:
      slot*: UInt256
  
  LazyDataSource* = ref object of RootObj
  NoLazyDataSource* = ref object of LazyDataSource
  RealLazyDataSource* = ref object of LazyDataSource
    client*: RpcClient
  # Used for unit testing. Contains some prepopulated data.
  FakeLazyDataSource* = ref object of LazyDataSource
    fakePairs*: seq[tuple[key, val: array[32, byte]]]
  
  AsyncOperationFactory* = ref object of RootObj
    lazyDataSource*: LazyDataSource


# Maybe it's not worth having these here, the callers could just
# create the Vm2AsyncOperation values directly, but I like having
# a cleaner-looking interface.
proc ifNecessaryGetStorage*(slot: UInt256): Vm2AsyncOperation =
  Vm2AsyncOperation(kind: aokGetStorage, slot: slot)
