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
  eth/[common, p2p, p2p/private/p2p_types],
  ../../types

include
  ./eth_versions # early compile time list of proto versions

logScope:
  topics = "eth-wire"

type
  NewBlockHashesAnnounce* = object
    hash*: Hash256
    number*: BlockNumber

  ChainForkId* = object
    forkHash*: array[4, byte] # The RLP encoding must be exactly 4 bytes.
    forkNext*: uint64         # The RLP encoding must be variable-length

  EthWireBase* = ref object of RootRef
    chainId*: ChainId

  EthState* = object
    totalDifficulty*: DifficultyInt
    genesisHash*: Hash256
    bestBlockHash*: Hash256
    forkId*: ChainForkId

  EthPeerState* = ref object of RootRef
    initialized*: bool
    bestBlockHash*: Hash256
    bestDifficulty*: DifficultyInt

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
                    hashes: openArray[Hash256]):
                      Result[seq[seq[Receipt]], string]
    {.base, gcsafe.} =
  notImplemented("getReceipts")

method getPooledTxs*(ctx: EthWireBase,
                     hashes: openArray[Hash256]):
                       Result[seq[PooledTransaction], string]
    {.base, gcsafe.} =
  notImplemented("getPooledTxs")

method getBlockBodies*(ctx: EthWireBase,
                       hashes: openArray[Hash256]):
                         Result[seq[BlockBody], string]
    {.base, gcsafe.} =
  notImplemented("getBlockBodies")

method getBlockHeaders*(ctx: EthWireBase,
                        req: BlocksRequest):
                          Result[seq[BlockHeader], string]
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

# Most recent setting, only the latest version is active
when 68 in ethVersions:
  method handleAnnouncedTxsHashes*(
    ctx: EthWireBase;
    peer: Peer;
    txTypes: Blob;
    txSizes: openArray[int];
    txHashes: openArray[Hash256];
      ): Result[void, string]
      {.base, gcsafe.} =
    notImplemented("handleAnnouncedTxsHashes/eth68")
else:
  method handleAnnouncedTxsHashes*(ctx: EthWireBase,
                                   peer: Peer,
                                   txHashes: openArray[Hash256]):
                                     Result[void, string]
      {.base, gcsafe.} =
    notImplemented("handleAnnouncedTxsHashes")

method handleNewBlockHashes*(ctx: EthWireBase,
                             peer: Peer,
                             hashes: openArray[NewBlockHashesAnnounce]):
                               Result[void, string]
    {.base, gcsafe.} =
  notImplemented("handleNewBlockHashes")

# Legacy setting, currently the latest version is active only
when 66 in ethVersions and ethVersions.len == 1:
  method getStorageNodes*(ctx: EthWireBase,
                          hashes: openArray[Hash256]):
                            Result[seq[Blob], string]
      {.base, gcsafe.} =
    notImplemented("getStorageNodes")

  method handleNodeData*(ctx: EthWireBase,
                         peer: Peer,
                         data: openArray[Blob]):
                           Result[void, string]
      {.base, gcsafe.} =
    notImplemented("handleNodeData")
