from chronos import Future
from stint import UInt256
from eth/common import BlockNumber, EthAddress, Hash256
from eth/trie/db import TrieDatabaseRef
from ../../../db/db_chain import BaseChainDB

type
  LazyDataSource* = ref object of RootObj
    ifNecessaryGetSlots*:       proc(db: TrieDatabaseRef, blockNumber: BlockNumber, stateRoot: Hash256, address: EthAddress, slots: seq[UInt256], newStateRootForSanityChecking: Hash256): Future[void] {.gcsafe.}
    ifNecessaryGetCode*:        proc(db: TrieDatabaseRef, blockNumber: BlockNumber, stateRoot: Hash256, address: EthAddress, newStateRootForSanityChecking: Hash256): Future[void] {.gcsafe.}
    ifNecessaryGetAccount*:     proc(db: TrieDatabaseRef, blockNumber: BlockNumber, stateRoot: Hash256, address: EthAddress, newStateRootForSanityChecking: Hash256): Future[void] {.gcsafe.}
    ifNecessaryGetBlockHeader*: proc(chainDB: BaseChainDB, blockNumber: BlockNumber): Future[void] {.gcsafe.}

  # FIXME-Adam: maybe don't even bother having two separate objects,
  # just make AsyncOperationFactory be the one that stores the procs.
  AsyncOperationFactory* = ref object of RootObj
    lazyDataSource*: LazyDataSource
