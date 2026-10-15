# nimbus_verified_proxy
# Copyright (c) 2026 Status Research & Development GmbH
# Licensed and distributed under either of
#   * MIT license (license terms in the root directory or at https://opensource.org/licenses/MIT).
#   * Apache v2 license (license terms in the root directory or at https://www.apache.org/licenses/LICENSE-2.0).
# at your option. This file may not be copied, modified, or distributed except according to those terms.

{.push raises: [], gcsafe.}

import
  results,
  chronicles,
  json_rpc/[rpcserver, rpcclient],
  web3/[eth_api, eth_api_types],
  ../../execution_chain/core/eip4844,
  ../../execution_chain/db/core_db/memory_only,
  ../../execution_chain/common/common,
  ../engine/types,
  ../engine/engine,
  ../engine/blocks,
  ../engine/rpc_frontend,
  ./op_chain_params

logScope:
  topics = "vp_op"

template penaltyOr[T](engine: RpcVerificationEngine, r: EngineResult[T]): T =
  let penaltyOrResult: EngineResult[T] = r
  if penaltyOrResult.isErr():
    engine.applyPenalty(penaltyOrResult.error)
    result = err(typeof(result), penaltyOrResult.error)
    return
  penaltyOrResult.unsafeGet()

proc getOpExecutionApiFrontend*(
    opEngine: RpcVerificationEngine, l1Engine: RpcVerificationEngine
): ExecutionApiFrontend =
  # the OP frontend only deviates where the L2 needs the L1 fork schedule or
  # where a tag has to be pinned to a verified block before it is forwarded
  var frontend = getExecutionApiFrontend(opEngine, l1Engine)

  frontend.eth_blobBaseFee = proc(): Future[EngineResult[UInt256]] {.
      async: (raises: [CancelledError])
  .} =
    ?l1Engine.requireSynced()
    trace "Received query", meth = "eth_blobBaseFee"

    let db = DefaultDbMemory.newCoreDbRef()
    defer:
      db.close()

    # the L2 follows the L1 fork schedule, so configure the common with the L1 chain id
    let l1ChainId = opL1ChainId(opEngine.chainId).valueOr:
      return err((InvalidDataError, "unknown op chainId: " & error, UNTAGGED))
    let com = CommonRef.new(
      db,
      config = chainConfigForNetwork(l1ChainId),
      initializeDb = false,
      statelessProvider = true,
    )

    let header = opEngine.penaltyOr(await opEngine.getVerifiedHeader(blockId("latest")))

    if header.excessBlobGas.isNone():
      return err(
        (UnavailableDataError, "excessBlobGas missing from latest header", UNTAGGED)
      )
    let blobBaseFee =
      getBlobBaseFee(header.excessBlobGas.get, com, com.toHardFork(header))

    ok(blobBaseFee)

  frontend
