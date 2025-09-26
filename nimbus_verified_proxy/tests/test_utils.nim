# Nimbus
# Copyright (c) 2025 Status Research & Development GmbH
# Licensed and distributed under either of
#   * MIT license (license terms in the root directory or at https://opensource.org/licenses/MIT).
#   * Apache v2 license (license terms in the root directory or at https://www.apache.org/licenses/LICENSE-2.0).
# at your option. This file may not be copied, modified, or distributed except according to those terms.

{.used.}
{.push raises: [], gcsafe.}

import
  stint,
  chronos,
  json_rpc/jsonmarshal,
  stew/[io2, byteutils],
  web3/[eth_api_types, conversions],
  eth/common/eth_types_rlp,
  ../../execution_chain/common/common,
  ../engine/types,
  ../engine/engine,
  ./test_api_backend

proc getBlockFromJson*(filepath: string): BlockObject {.raises: [SerializationError].} =
  let blkBytes = readAllBytes(filepath)
  JrpcConv.decode(blkBytes.get, BlockObject)

proc getReceiptsFromJson*(
    filepath: string
): seq[ReceiptObject] {.raises: [SerializationError].} =
  let rxBytes = readAllBytes(filepath)
  JrpcConv.decode(rxBytes.get, seq[ReceiptObject])

proc getLogsFromJson*(
    filepath: string
): seq[LogObject] {.raises: [SerializationError].} =
  let logBytes = readAllBytes(filepath)
  JrpcConv.decode(logBytes.get, seq[LogObject])

proc getProofFromJson*(
    filepath: string
): ProofResponse {.raises: [SerializationError].} =
  let proofBytes = readAllBytes(filepath)
  JrpcConv.decode(proofBytes.get, ProofResponse)

proc getAccessListFromJson*(
    filepath: string
): AccessListResult {.raises: [SerializationError].} =
  let filebytes = readAllBytes(filepath)
  JrpcConv.decode(filebytes.get, AccessListResult)

proc getCodeFromJson*(
    filepath: string
): seq[byte] {.raises: [SerializationError, ValueError].} =
  let filebytes = readAllBytes(filepath)
  JrpcConv.decode(filebytes.get, string).hexToSeqByte()

template `==`*(b1: BlockObject, b2: BlockObject): bool =
  JrpcConv.encode(b1).JsonString == JrpcConv.encode(b2).JsonString

template `==`*(tx1: TransactionObject, tx2: TransactionObject): bool =
  JrpcConv.encode(tx1).JsonString == JrpcConv.encode(tx2).JsonString

template `==`*(rx1: ReceiptObject, rx2: ReceiptObject): bool =
  JrpcConv.encode(rx1).JsonString == JrpcConv.encode(rx2).JsonString

template `==`*(rxs1: seq[ReceiptObject], rxs2: seq[ReceiptObject]): bool =
  JrpcConv.encode(rxs1).JsonString == JrpcConv.encode(rxs2).JsonString

template `==`*(logs1: seq[LogObject], logs2: seq[LogObject]): bool =
  JrpcConv.encode(logs1).JsonString == JrpcConv.encode(logs2).JsonString

proc initTestEngine*(
    testState: TestApiState, headerCacheLen: int, maxBlockWalk: uint64
): RpcVerificationEngine {.raises: [CatchableError].} =
  let
    engineConf = RpcVerificationEngineConf(
      chainId: 1.u256,
      maxBlockWalk: maxBlockWalk,
      headerStoreLen: headerCacheLen,
      accountCacheLen: 1,
      codeCacheLen: 1,
      storageCacheLen: 1,
    )
    engine = RpcVerificationEngine.init(engineConf)

  engine.backend = initTestApiBackend(testState)

  return engine
