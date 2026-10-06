# nimbus_verified_proxy
# Copyright (c) 2026 Status Research & Development GmbH
# Licensed and distributed under either of
#   * MIT license (license terms in the root directory or at https://opensource.org/licenses/MIT).
#   * Apache v2 license (license terms in the root directory or at https://www.apache.org/licenses/LICENSE-2.0).
# at your option. This file may not be copied, modified, or distributed except according to those terms.

{.push raises: [], gcsafe.}

import
  results,
  chronos,
  chronicles,
  eth/common/[hashes, headers, base, eth_types_rlp],
  web3/eth_api_types,
  ../engine/types,
  ../engine/engine,
  ../engine/header_store,
  ../engine/accounts,
  ../engine/blocks,
  ./op_chain_params,
  ./op_anchor_utils

logScope:
  topics = "vp_op"

proc verifyOutputRoot(
    opEngine: RpcVerificationEngine,
    proposedOutputRoot: Hash32,
    blkNum: base.BlockNumber,
): Future[EngineResult[(Header, Hash32)]] {.async: (raises: [CancelledError]).} =
  let
    blkTag = BlockTag(kind: bidNumber, number: Quantity(blkNum))
    (backend, backendIdx) = ?(opEngine.executionBackendFor(GetBlockByNumber))
    blk = ?((await backend.eth_getBlockByNumber(blkTag, false)).tagBackend(backendIdx))
    header = convHeader(blk)

  if header.number != blkNum:
    let e = (VerificationError, "op-stack block number mismatch", backendIdx)
    opEngine.applyPenalty(e)
    return err(e)

  if header.computeBlockHash != blk.hash:
    let e = (VerificationError, "op-stack header hash mismatch", backendIdx)
    opEngine.applyPenalty(e)
    return err(e)

  let messagePasserAccount = ?(
    await opEngine.getAccount(
      L2L1_MESSAGE_PASSER_CONTRACT, header.number, header.stateRoot
    )
  )

  if not matchesOutputRoot(
    proposedOutputRoot, header.stateRoot, messagePasserAccount.storageRoot, blk.hash
  ):
    let e = (
      VerificationError,
      "recomputed op-stack output root does not match the root posted on L1", backendIdx,
    )
    opEngine.applyPenalty(e)
    return err(e)

  ok((header, blk.hash))

proc opSyncOnce*(
    opEngine: RpcVerificationEngine, l1Engine: RpcVerificationEngine
): Future[EngineResult[void]] {.async: (raises: [CancelledError]).} =
  await opEngine.syncLock.acquire()
  defer:
    try:
      opEngine.syncLock.release()
    except AsyncLockError:
      discard

  let
    l1Anchors = ?l1Engine.snapshotAnchors()
    l1LatestHeader =
      ?(await l1Engine.getVerifiedHeader(blockId("latest"), Opt.some(l1Anchors)))
    l1FinalizedHeader =
      ?(await l1Engine.getVerifiedHeader(blockId("finalized"), Opt.some(l1Anchors)))

  # the L2 chainId identifies the OP chain whose (trusted) SystemConfig we read from
  let systemConfig = getSystemConfig(opEngine.chainId).valueOr:
    return err((InvalidDataError, "no system config for chainId: " & error, UNTAGGED))

  # get latest contracts from system config
  let contracts = ?(await l1Engine.resolveContracts(systemConfig, l1LatestHeader))

  # get safe block
  let
    proposal =
      ?(await l1Engine.readLatestGame(contracts.disputeGameFactory, l1LatestHeader))
    (safeHeader, safeHash) =
      ?(await opEngine.verifyOutputRoot(proposal.outputRoot, proposal.l2BlockNumber))

  opEngine.headerStore.put(safeHeader, safeHash, Safe)
  opEngine.headerStore.putHash(safeHash, Safe)
  info "op-stack safe header added", number = safeHeader.number, hash = safeHash

  # get finalized block
  let
    anchor = (
      await l1Engine.readAnchorRoot(contracts.anchorStateRegistry, l1FinalizedHeader)
    ).valueOr:
      debug "no finalized OP anchor yet", err = error.errMsg
      return ok()
    (finalizedHeader, finalizedHash) =
      ?(await opEngine.verifyOutputRoot(anchor.outputRoot, anchor.l2BlockNumber))

  opEngine.headerStore.put(finalizedHeader, finalizedHash, Finalized)
  opEngine.headerStore.putHash(finalizedHash, Finalized)
  info "op-stack finalized anchor added to header store",
    number = finalizedHeader.number, hash = finalizedHash

  ok()

