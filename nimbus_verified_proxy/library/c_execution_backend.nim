# nimbus_verified_proxy
# Copyright (c) 2025-2026 Status Research & Development GmbH
# Licensed and distributed under either of
#   * MIT license (license terms in the root directory or at https://opensource.org/licenses/MIT).
#   * Apache v2 license (license terms in the root directory or at https://www.apache.org/licenses/LICENSE-2.0).
# at your option. This file may not be copied, modified, or distributed except according to those terms.

{.push raises: [], gcsafe.}

import chronos, web3/[eth_api_types, conversions], ../engine/types, ./types, ./utils

proc newExecTransportCtx*(url, name, params: string): TransportExecutionContext =
  TransportExecutionContext(
    url: url, name: name, params: params, fut: newFuture[string]()
  )

proc deliverExecutionTransport*(
    status: cint, res: cstring, userData: pointer
) {.cdecl, exportc, gcsafe, raises: [].} =
  let tctx = cast[TransportExecutionContext](userData)
  let response =
    if res != nil:
      $res
    else:
      ""
  if status == RET_CANCELLED:
    tctx.fut.cancelSoon()
  elif status == RET_SUCCESS:
    tctx.fut.complete(response)
  else:
    tctx.fut.fail(newException(CatchableError, response))

proc execCtxUrl*(userData: pointer): cstring {.cdecl, exportc, gcsafe, raises: [].} =
  cast[TransportExecutionContext](userData).url.cstring

proc execCtxName*(userData: pointer): cstring {.cdecl, exportc, gcsafe, raises: [].} =
  cast[TransportExecutionContext](userData).name.cstring

proc execCtxParams*(userData: pointer): cstring {.cdecl, exportc, gcsafe, raises: [].} =
  cast[TransportExecutionContext](userData).params.cstring

proc getExecutionApiBackend*(
    ctx: ptr Context, url: string, transportProc: ExecutionTransportProc
): ExecutionApiBackend =
  let
    ethChainIdProc = proc(): Future[EngineResult[UInt256]] {.
        async: (raises: [CancelledError])
    .} =
      let tctx = newExecTransportCtx(url, "eth_chainId", "[]")
      transportProc(ctx, deliverExecutionTransport, cast[pointer](tctx))
      let raw =
        try:
          await tctx.fut
        except CancelledError as e:
          raise e
        except CatchableError as e:
          return err((BackendError, e.msg, UNTAGGED))
      let r = unpackArg(raw, UInt256)
      if r.isErr():
        return err((BackendDecodingError, r.error, UNTAGGED))
      return ok(r.get())

    getBlockByHashProc = proc(
        blkHash: Hash32, fullTransactions: bool
    ): Future[EngineResult[BlockObject]] {.async: (raises: [CancelledError]).} =
      let
        blkHashSer = packArg(blkHash).valueOr:
          return err((BackendEncodingError, error, UNTAGGED))
        params =
          "[" & blkHashSer & ", " & (if fullTransactions: "true" else: "false") & "]"
        tctx = newExecTransportCtx(url, "eth_getBlockByHash", params)
      transportProc(ctx, deliverExecutionTransport, cast[pointer](tctx))
      let raw =
        try:
          await tctx.fut
        except CancelledError as e:
          raise e
        except CatchableError as e:
          return err((BackendError, e.msg, UNTAGGED))
      let r = unpackArg(raw, BlockObject)
      if r.isErr():
        return err((BackendDecodingError, r.error, UNTAGGED))
      return ok(r.get())

    getBlockByNumberProc = proc(
        blkNum: BlockTag, fullTransactions: bool
    ): Future[EngineResult[BlockObject]] {.async: (raises: [CancelledError]).} =
      let
        blkNumSer = packArg(blkNum).valueOr:
          return err((BackendEncodingError, error, UNTAGGED))
        params =
          "[" & blkNumSer & ", " & (if fullTransactions: "true" else: "false") & "]"
        tctx = newExecTransportCtx(url, "eth_getBlockByNumber", params)
      transportProc(ctx, deliverExecutionTransport, cast[pointer](tctx))
      let raw =
        try:
          await tctx.fut
        except CancelledError as e:
          raise e
        except CatchableError as e:
          return err((BackendError, e.msg, UNTAGGED))
      let r = unpackArg(raw, BlockObject)
      if r.isErr():
        return err((BackendDecodingError, r.error, UNTAGGED))
      return ok(r.get())

    getProofProc = proc(
        address: Address, slots: seq[UInt256], blockId: BlockTag
    ): Future[EngineResult[ProofResponse]] {.async: (raises: [CancelledError]).} =
      let
        addressSer = packArg(address).valueOr:
          return err((BackendEncodingError, error, UNTAGGED))
        slotsSer = packArg(slots).valueOr:
          return err((BackendEncodingError, error, UNTAGGED))
        blockIdSer = packArg(blockId).valueOr:
          return err((BackendEncodingError, error, UNTAGGED))
        tctx = newExecTransportCtx(
          url,
          "eth_getProof",
          "[" & addressSer & ", " & slotsSer & ", " & blockIdSer & "]",
        )
      transportProc(ctx, deliverExecutionTransport, cast[pointer](tctx))
      let raw =
        try:
          await tctx.fut
        except CancelledError as e:
          raise e
        except CatchableError as e:
          return err((BackendError, e.msg, UNTAGGED))
      let r = unpackArg(raw, ProofResponse)
      if r.isErr():
        return err((BackendDecodingError, r.error, UNTAGGED))
      return ok(r.get())

    createAccessListProc = proc(
        txArgs: TransactionArgs, blockId: BlockTag
    ): Future[EngineResult[AccessListResult]] {.async: (raises: [CancelledError]).} =
      let
        txArgsSer = packArg(txArgs).valueOr:
          return err((BackendEncodingError, error, UNTAGGED))
        blockIdSer = packArg(blockId).valueOr:
          return err((BackendEncodingError, error, UNTAGGED))
        tctx = newExecTransportCtx(
          url, "eth_createAccessList", "[" & txArgsSer & ", " & blockIdSer & "]"
        )
      transportProc(ctx, deliverExecutionTransport, cast[pointer](tctx))
      let raw =
        try:
          await tctx.fut
        except CancelledError as e:
          raise e
        except CatchableError as e:
          return err((BackendError, e.msg, UNTAGGED))
      let r = unpackArg(raw, AccessListResult)
      if r.isErr():
        return err((BackendDecodingError, r.error, UNTAGGED))
      return ok(r.get())

    getCodeProc = proc(
        address: Address, blockId: BlockTag
    ): Future[EngineResult[seq[byte]]] {.async: (raises: [CancelledError]).} =
      let
        addressSer = packArg(address).valueOr:
          return err((BackendEncodingError, error, UNTAGGED))
        blockIdSer = packArg(blockId).valueOr:
          return err((BackendEncodingError, error, UNTAGGED))
        tctx = newExecTransportCtx(
          url, "eth_getCode", "[" & addressSer & ", " & blockIdSer & "]"
        )
      transportProc(ctx, deliverExecutionTransport, cast[pointer](tctx))
      let raw =
        try:
          await tctx.fut
        except CancelledError as e:
          raise e
        except CatchableError as e:
          return err((BackendError, e.msg, UNTAGGED))
      let r = unpackArg(raw, seq[byte])
      if r.isErr():
        return err((BackendDecodingError, r.error, UNTAGGED))
      return ok(r.get())

    getTransactionByHashProc = proc(
        txHash: Hash32
    ): Future[EngineResult[TransactionObject]] {.async: (raises: [CancelledError]).} =
      let
        txHashSer = packArg(txHash).valueOr:
          return err((BackendEncodingError, error, UNTAGGED))
        tctx =
          newExecTransportCtx(url, "eth_getTransactionByHash", "[" & txHashSer & "]")
      transportProc(ctx, deliverExecutionTransport, cast[pointer](tctx))
      let raw =
        try:
          await tctx.fut
        except CancelledError as e:
          raise e
        except CatchableError as e:
          return err((BackendError, e.msg, UNTAGGED))
      let r = unpackArg(raw, TransactionObject)
      if r.isErr():
        return err((BackendDecodingError, r.error, UNTAGGED))
      return ok(r.get())

    getTransactionReceiptProc = proc(
        txHash: Hash32
    ): Future[EngineResult[ReceiptObject]] {.async: (raises: [CancelledError]).} =
      let
        txHashSer = packArg(txHash).valueOr:
          return err((BackendEncodingError, error, UNTAGGED))
        tctx =
          newExecTransportCtx(url, "eth_getTransactionReceipt", "[" & txHashSer & "]")
      transportProc(ctx, deliverExecutionTransport, cast[pointer](tctx))
      let raw =
        try:
          await tctx.fut
        except CancelledError as e:
          raise e
        except CatchableError as e:
          return err((BackendError, e.msg, UNTAGGED))
      let r = unpackArg(raw, ReceiptObject)
      if r.isErr():
        return err((BackendDecodingError, r.error, UNTAGGED))
      return ok(r.get())

    getBlockReceiptsProc = proc(
        blockId: BlockTag
    ): Future[EngineResult[Opt[seq[ReceiptObject]]]] {.
        async: (raises: [CancelledError])
    .} =
      let
        blockIdSer = packArg(blockId).valueOr:
          return err((BackendEncodingError, error, UNTAGGED))
        tctx = newExecTransportCtx(url, "eth_getBlockReceipts", "[" & blockIdSer & "]")
      transportProc(ctx, deliverExecutionTransport, cast[pointer](tctx))
      let raw =
        try:
          await tctx.fut
        except CancelledError as e:
          raise e
        except CatchableError as e:
          return err((BackendError, e.msg, UNTAGGED))
      let r = unpackArg(raw, Opt[seq[ReceiptObject]])
      if r.isErr():
        return err((BackendDecodingError, r.error, UNTAGGED))
      return ok(r.get())

    getLogsProc = proc(
        filterOptions: FilterOptions
    ): Future[EngineResult[seq[LogObject]]] {.async: (raises: [CancelledError]).} =
      let
        filterOptionsSer = packArg(filterOptions).valueOr:
          return err((BackendEncodingError, error, UNTAGGED))
        tctx = newExecTransportCtx(url, "eth_getLogs", "[" & filterOptionsSer & "]")
      transportProc(ctx, deliverExecutionTransport, cast[pointer](tctx))
      let raw =
        try:
          await tctx.fut
        except CancelledError as e:
          raise e
        except CatchableError as e:
          return err((BackendError, e.msg, UNTAGGED))
      let r = unpackArg(raw, seq[LogObject])
      if r.isErr():
        return err((BackendDecodingError, r.error, UNTAGGED))
      return ok(r.get())

    feeHistoryProc = proc(
        blockCount: Quantity, newestBlock: BlockTag, rewardPercentiles: seq[int]
    ): Future[EngineResult[FeeHistoryResult]] {.async: (raises: [CancelledError]).} =
      let
        blockCountSer = packArg(blockCount).valueOr:
          return err((BackendEncodingError, error, UNTAGGED))
        newestBlockSer = packArg(newestBlock).valueOr:
          return err((BackendEncodingError, error, UNTAGGED))
        rewardPercentilesSer = packArg(rewardPercentiles).valueOr:
          return err((BackendEncodingError, error, UNTAGGED))
        tctx = newExecTransportCtx(
          url,
          "eth_feeHistory",
          "[" & blockCountSer & ", " & newestBlockSer & ", " & rewardPercentilesSer & "]",
        )
      transportProc(ctx, deliverExecutionTransport, cast[pointer](tctx))
      let raw =
        try:
          await tctx.fut
        except CancelledError as e:
          raise e
        except CatchableError as e:
          return err((BackendError, e.msg, UNTAGGED))
      let r = unpackArg(raw, FeeHistoryResult)
      if r.isErr():
        return err((BackendDecodingError, r.error, UNTAGGED))
      return ok(r.get())

    sendRawTxProc = proc(
        txBytes: seq[byte]
    ): Future[EngineResult[Hash32]] {.async: (raises: [CancelledError]).} =
      let
        txBytesSer = packArg(txBytes).valueOr:
          return err((BackendEncodingError, error, UNTAGGED))
        tctx =
          newExecTransportCtx(url, "eth_sendRawTransaction", "[" & txBytesSer & "]")
      transportProc(ctx, deliverExecutionTransport, cast[pointer](tctx))
      let raw =
        try:
          await tctx.fut
        except CancelledError as e:
          raise e
        except CatchableError as e:
          return err((BackendError, e.msg, UNTAGGED))
      let r = unpackArg(raw, Hash32)
      if r.isErr():
        return err((BackendDecodingError, r.error, UNTAGGED))
      return ok(r.get())

  ExecutionApiBackend(
    eth_chainId: ethChainIdProc,
    eth_getBlockByHash: getBlockByHashProc,
    eth_getBlockByNumber: getBlockByNumberProc,
    eth_getProof: getProofProc,
    eth_createAccessList: createAccessListProc,
    eth_getCode: getCodeProc,
    eth_getBlockReceipts: getBlockReceiptsProc,
    eth_getLogs: getLogsProc,
    eth_getTransactionByHash: getTransactionByHashProc,
    eth_getTransactionReceipt: getTransactionReceiptProc,
    eth_feeHistory: feeHistoryProc,
    eth_sendRawTransaction: sendRawTxProc,
  )
