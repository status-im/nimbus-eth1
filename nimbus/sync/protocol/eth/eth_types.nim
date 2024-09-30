# Nimbus
# Copyright (c) 2018-2024 Status Research & Development GmbH
# Licensed under either of
#  * Apache License, version 2.0, ([LICENSE-APACHE](LICENSE-APACHE) or
#    http://www.apache.org/licenses/LICENSE-2.0)
#  * MIT license ([LICENSE-MIT](LICENSE-MIT) or
#    http://opensource.org/licenses/MIT)
# at your option. This file may not be copied, modified, or distributed except
# according to those terms.

{.push raises: [].}

import
  chronicles,
  results,
  eth/[common, p2p, p2p/private/p2p_types]

logScope:
  topics = "eth-wire"

type
  NewBlockHashesAnnounce* = object
    hash*: Hash32
    number*: BlockNumber

  ChainForkId* = object
    forkHash*: array[4, byte] # The RLP encoding must be exactly 4 bytes.
    forkNext*: uint64         # The RLP encoding must be variable-length

  EthWireBase* = ref object of RootRef

  EthState* = object
    totalDifficulty*: DifficultyInt
    genesisHash*: Hash32
    bestBlockHash*: Hash32
    forkId*: ChainForkId

  EthPeerState* = ref object of RootRef
    initialized*: bool
    bestBlockHash*: Hash32
    bestDifficulty*: DifficultyInt

  EthBlocksRequest* = object
    startBlock*: BlockHashOrNumber
    maxResults*, skip*: uint
    reverse*: bool

const
  maxStateFetch* = 384
  maxBodiesFetch* = 128
  maxReceiptsFetch* = 256
  maxHeadersFetch* = 192

proc notImplemented(name: string) =
  debug "Method not implemented", meth = name

method getStatus*(ctx: EthWireBase): Result[EthState, string]
    {.base, gcsafe.} =
  notImplemented("getStatus")

method getReceipts*(ctx: EthWireBase,
                    hashes: openArray[Hash32]):
                      Result[seq[seq[Receipt]], string]
    {.base, gcsafe.} =
  notImplemented("getReceipts")

method getPooledTxs*(ctx: EthWireBase,
                     hashes: openArray[Hash32]):
                       Result[seq[PooledTransaction], string]
    {.base, gcsafe.} =
  notImplemented("getPooledTxs")

method getBlockBodies*(ctx: EthWireBase,
                       hashes: openArray[Hash32]):
                         Result[seq[BlockBody], string]
    {.base, gcsafe.} =
  notImplemented("getBlockBodies")

method getBlockHeaders*(ctx: EthWireBase,
                        req: EthBlocksRequest):
                          Result[seq[Header], string]
    {.base, gcsafe.} =
  notImplemented("getBlockHeaders")

method handleNewBlock*(ctx: EthWireBase,
                       peer: Peer,
                       blk: EthBlock,
                       totalDifficulty: DifficultyInt):
                         Result[void, string]
    {.base, gcsafe.} =
  notImplemented("handleNewBlock")

method handleAnnouncedTxs*(ctx: EthWireBase,
                           peer: Peer,
                           txs: openArray[Transaction]):
                             Result[void, string]
    {.base, gcsafe.} =
  notImplemented("handleAnnouncedTxs")

method handleAnnouncedTxsHashes*(
  ctx: EthWireBase;
  peer: Peer;
  txTypes: seq[byte];
  txSizes: openArray[int];
  txHashes: openArray[Hash32];
    ): Result[void, string]
    {.base, gcsafe.} =
  notImplemented("handleAnnouncedTxsHashes/eth68")

method handleNewBlockHashes*(ctx: EthWireBase,
                             peer: Peer,
                             hashes: openArray[NewBlockHashesAnnounce]):
                               Result[void, string]
    {.base, gcsafe.} =
  notImplemented("handleNewBlockHashes")

