# Nimbus
# Copyright (c) 2025-2026 Status Research & Development GmbH
# Licensed and distributed under either of
#   * MIT license (license terms in the root directory or at https://opensource.org/licenses/MIT).
#   * Apache v2 license (license terms in the root directory or at https://www.apache.org/licenses/LICENSE-2.0).
# at your option. This file may not be copied, modified, or distributed except according to those terms.

{.used.}
{.push raises: [], gcsafe.}

import
  stint,
  chronos,
  stew/[io2, byteutils],
  web3/[eth_api_types, conversions],
  eth/common/eth_types_rlp,
  ../../execution_chain/common/common,
  ../engine/types,
  ../engine/engine,
  ./test_api_backend

type TestProxyError* = object of CatchableError

proc getBlockFromJson*(filepath: string): BlockObject {.raises: [SerializationError].} =
  let blkBytes = readAllBytes(filepath)
  EthJson.decode(blkBytes.get, BlockObject)

proc getReceiptsFromJson*(
    filepath: string
): seq[ReceiptObject] {.raises: [SerializationError].} =
  let rxBytes = readAllBytes(filepath)
  EthJson.decode(rxBytes.get, seq[ReceiptObject])

proc getLogsFromJson*(
    filepath: string
): seq[LogObject] {.raises: [SerializationError].} =
  let logBytes = readAllBytes(filepath)
  EthJson.decode(logBytes.get, seq[LogObject])

proc getProofFromJson*(
    filepath: string
): ProofResponse {.raises: [SerializationError].} =
  let proofBytes = readAllBytes(filepath)
  EthJson.decode(proofBytes.get, ProofResponse)

proc getAccessListFromJson*(
    filepath: string
): AccessListResult {.raises: [SerializationError].} =
  let filebytes = readAllBytes(filepath)
  EthJson.decode(filebytes.get, AccessListResult)

proc getCodeFromJson*(
    filepath: string
): seq[byte] {.raises: [SerializationError, ValueError].} =
  let filebytes = readAllBytes(filepath)
  EthJson.decode(filebytes.get, string).hexToSeqByte()

template `==`*(b1: BlockObject, b2: BlockObject): bool =
  EthJson.encode(b1).JsonString == EthJson.encode(b2).JsonString

template `==`*(tx1: TransactionObject, tx2: TransactionObject): bool =
  EthJson.encode(tx1).JsonString == EthJson.encode(tx2).JsonString

template `==`*(rx1: ReceiptObject, rx2: ReceiptObject): bool =
  EthJson.encode(rx1).JsonString == EthJson.encode(rx2).JsonString

template `==`*(rxs1: seq[ReceiptObject], rxs2: seq[ReceiptObject]): bool =
  EthJson.encode(rxs1).JsonString == EthJson.encode(rxs2).JsonString

template `==`*(logs1: seq[LogObject], logs2: seq[LogObject]): bool =
  EthJson.encode(logs1).JsonString == EthJson.encode(logs2).JsonString

proc initTestEngine*(
    testState: TestApiState, headerCacheLen: int, maxBlockWalk: uint64
): EngineResult[RpcVerificationEngine] =
  let
    engineConf = RpcVerificationEngineConf(
      chainId: 1.u256,
      maxBlockWalk: maxBlockWalk,
      headerStoreLen: headerCacheLen,
      accountCacheLen: 1,
      codeCacheLen: 1,
      storageCacheLen: 1,
      parallelBlockDownloads: 2, # >1 required for block walk tests
    )
    engine = ?RpcVerificationEngine.init(engineConf)

  engine.backend = initTestApiBackend(testState)

  ok(engine)
