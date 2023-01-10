import
  std/options,
  chronicles,
  eth/[common, p2p, p2p/private/p2p_types, rlp],
  ../../types

type
  NewBlockHashesAnnounce* = object
    hash*: Hash256
    number*: BlockNumber

  ChainForkId* = object
    forkHash*: array[4, byte] # The RLP encoding must be exactly 4 bytes.
    forkNext*: BlockNumber    # The RLP encoding must be variable-length

  EthWireBase* = ref object of RootRef

  EthState* = object
    totalDifficulty*: DifficultyInt
    genesisHash*: Hash256
    bestBlockHash*: Hash256
    forkId*: ChainForkId

  PeerState* = ref object of RootRef
    initialized*: bool
    bestBlockHash*: Hash256
    bestDifficulty*: DifficultyInt

  PooledTx* = Option[Transaction]

const
  maxStateFetch* = 384
  maxBodiesFetch* = 128
  maxReceiptsFetch* = 256
  maxHeadersFetch* = 192

proc read*(rlp: var Rlp, T: type seq[PooledTx]): T =
  ## RLP Mixin
  if not rlp.isList:
    raise newException(RlpTypeMismatch,
      "Pooled transactions list expected, but source RLP is not a list")
  for w in rlp:
    if w.hasData:
      result.add some(w.read(Transaction))
    else:
      result.add none(Transaction)

proc append*(writer: var RlpWriter; txs: openArray[PooledTx]) =
  ## RLP Mixin
  writer.startList(txs.len)
  for w in txs:
    if w.isNone:
      writer.append rlp.encode(seq[byte].default)
    else:
      let tx = w.unsafeGet
      if tx.txType == TxLegacy:
        writer.append tx
      else:
        writer.append rlp.encode(tx)

proc notImplemented(name: string) =
  debug "Method not implemented", meth = name

method getStatus*(ctx: EthWireBase): EthState {.base.} =
  notImplemented("getStatus")

method getReceipts*(ctx: EthWireBase, hashes: openArray[Hash256]): seq[seq[Receipt]] {.base.} =
  notImplemented("getReceipts")

method getPooledTxs*(ctx: EthWireBase, hashes: openArray[Hash256]): seq[PooledTx] {.base.} =
  notImplemented("getPooledTxs")

method getBlockBodies*(ctx: EthWireBase, hashes: openArray[Hash256]): seq[BlockBody] {.base.} =
  notImplemented("getBlockBodies")

method getBlockHeaders*(ctx: EthWireBase, req: BlocksRequest): seq[BlockHeader] {.base.} =
  notImplemented("getBlockHeaders")

method handleNewBlock*(ctx: EthWireBase, peer: Peer, blk: EthBlock, totalDifficulty: DifficultyInt) {.base.} =
  notImplemented("handleNewBlock")

method handleAnnouncedTxs*(ctx: EthWireBase, peer: Peer, txs: openArray[Transaction]) {.base.} =
  notImplemented("handleAnnouncedTxs")

method handleAnnouncedTxsHashes*(ctx: EthWireBase, peer: Peer, txHashes: openArray[Hash256]) {.base.} =
  notImplemented("handleAnnouncedTxsHashes")

method handleNewBlockHashes*(ctx: EthWireBase, peer: Peer, hashes: openArray[NewBlockHashesAnnounce]) {.base.} =
  notImplemented("handleNewBlockHashes")

when defined(legacy_eth66_enabled):
  method getStorageNodes*(ctx: EthWireBase, hashes: openArray[Hash256]): seq[Blob] {.base.} =
    notImplemented("getStorageNodes")

  method handleNodeData*(ctx: EthWireBase, peer: Peer, data: openArray[Blob]) {.base.} =
    notImplemented("handleNodeData")
