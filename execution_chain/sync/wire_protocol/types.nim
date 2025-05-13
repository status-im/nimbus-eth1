# Nimbus
# Copyright (c) 2018-2025 Status Research & Development GmbH
# Licensed under either of
#  * Apache License, version 2.0, ([LICENSE-APACHE](LICENSE-APACHE) or
#    http://www.apache.org/licenses/LICENSE-2.0)
#  * MIT license ([LICENSE-MIT](LICENSE-MIT) or
#    http://opensource.org/licenses/MIT)
# at your option. This file may not be copied, modified, or distributed except
# according to those terms.

{.push raises: [].}

import
  eth/common,
  ../../core/[chain, tx_pool]

type
  NewBlockHashesAnnounce* = object
    hash*: Hash32
    number*: BlockNumber

  ChainForkId* = object
    forkHash*: array[4, byte] # The RLP encoding must be exactly 4 bytes.
    forkNext*: uint64         # The RLP encoding must be variable-length

  Eth68State* = object
    totalDifficulty*: DifficultyInt
    genesisHash*: Hash32
    bestBlockHash*: Hash32
    forkId*: ChainForkId

  Eth68PeerState* = ref object of RootRef
    initialized*: bool
    bestBlockHash*: Hash32
    bestDifficulty*: DifficultyInt

  BlockHeadersRequest* = object
    startBlock*: BlockHashOrNumber
    maxResults*, skip*: uint
    reverse*: bool

  BlockBodiesRequest* =object
    blockHashes*: seq[Hash32]

  PooledTransactionsRequest* =object
    txHashes*: seq[Hash32]

  ReceiptsRequest* =object
    blockHashes*: seq[Hash32]

  EthWireRef* = ref object of RootRef
    chain* : ForkedChainRef
    txPool*: TxPoolRef
