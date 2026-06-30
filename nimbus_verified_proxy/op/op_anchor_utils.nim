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
  stint,
  eth/common/[hashes, headers, base, addresses],
  serialization,
  web3/eth_api_types,
  web3/encoding,
  web3/decoding,
  ../engine/types,
  ../engine/evm

type OpContracts* =
  tuple[
    disputeGameFactory: Address,
    optimismPortal: Address,
    anchorStateRegistry: Address,
    unsafeBlockSigner: Address,
  ]

const OUTPUT_ROOT_VERSION_V0* = default(array[32, byte])

func computeOutputRoot*(
    stateRoot: Hash32, messagePasserStorageRoot: Hash32, blockHash: Hash32
): Hash32 =
  let preimage =
    @OUTPUT_ROOT_VERSION_V0 & @(stateRoot.data) & @(messagePasserStorageRoot.data) &
    @(blockHash.data)
  keccak256(preimage)

func matchesOutputRoot*(
    postedRoot: Hash32,
    stateRoot: Hash32,
    messagePasserStorageRoot: Hash32,
    blockHash: Hash32,
): bool =
  computeOutputRoot(stateRoot, messagePasserStorageRoot, blockHash) == postedRoot

type L1OutputProposal* = object
  outputRoot*: Hash32
  l2BlockNumber*: base.BlockNumber

func hashFnSig(sig: string): seq[byte] =
  @(keccak256(sig).data[0 .. 3])

proc abiEncode[T](value: T): EngineResult[seq[byte]] =
  try:
    ok(Abi.encode(value))
  except SerializationError as e:
    err((InvalidDataError, "calldata ABI encode failed: " & e.msg, UNTAGGED))

proc abiDecode(output: seq[byte], T: typedesc): EngineResult[T] =
  try:
    ok(Abi.decode(output, T))
  except SerializationError as e:
    err((InvalidDataError, "call return ABI decode failed: " & e.msg, UNTAGGED))

proc makeCall(
    l1Engine: RpcVerificationEngine, to: Address, calldata: seq[byte], l1Header: Header
): Future[EngineResult[seq[byte]]] {.async: (raises: [CancelledError]).} =
  let tx = TransactionArgs(to: Opt.some(to), data: Opt.some(calldata))

  # we don't populate caches because its probably only one getStorageAt/getCode/getAccount per call anyways
  let callResult = (await l1Engine.evm.call(l1Header, tx, optimisticStateFetch = true)).valueOr:
    return
      err((VerificationError, "L1 eth_call for op-stack failed: " & error, UNTAGGED))

  if callResult.error.len() > 0:
    return err(
      (
        VerificationError,
        "L1 eth_call for op-stack reverted: " & callResult.error,
        UNTAGGED,
      )
    )

  ok(callResult.output)

proc resolveContracts*(
    l1Engine: RpcVerificationEngine, systemConfigContract: Address, l1Header: Header
): Future[EngineResult[OpContracts]] {.async: (raises: [CancelledError]).} =
  let
    dgfOut = ?(
      await l1Engine.makeCall(
        systemConfigContract, hashFnSig("disputeGameFactory()"), l1Header
      )
    )
    disputeGameFactory = ?abiDecode(dgfOut, Address)

    portalOut = ?(
      await l1Engine.makeCall(
        systemConfigContract, hashFnSig("optimismPortal()"), l1Header
      )
    )
    optimismPortal = ?abiDecode(portalOut, Address)

    signerOut = ?(
      await l1Engine.makeCall(
        systemConfigContract, hashFnSig("unsafeBlockSigner()"), l1Header
      )
    )
    unsafeBlockSigner = ?abiDecode(signerOut, Address)

    asrOut = ?(
      await l1Engine.makeCall(
        optimismPortal, hashFnSig("anchorStateRegistry()"), l1Header
      )
    )
    anchorStateRegistry = ?abiDecode(asrOut, Address)

  ok(
    (
      disputeGameFactory: disputeGameFactory,
      optimismPortal: optimismPortal,
      anchorStateRegistry: anchorStateRegistry,
      unsafeBlockSigner: unsafeBlockSigner,
    )
  )

# this gives us the latest proposed output root
proc readLatestGame*(
    l1Engine: RpcVerificationEngine, dgfContract: Address, l1Header: Header
): Future[EngineResult[L1OutputProposal]] {.async: (raises: [CancelledError]).} =
  let
    countOut =
      ?(await l1Engine.makeCall(dgfContract, hashFnSig("gameCount()"), l1Header))
    count = ?abiDecode(countOut, UInt256)

  if count.isZero:
    return err((UnavailableDataError, "no dispute games posted yet", UNTAGGED))

  let
    # get the latest game
    gameCalldata = hashFnSig("gameAtIndex(uint256)") & ?abiEncode(count - 1.u256)
    gameOut = ?(await l1Engine.makeCall(dgfContract, gameCalldata, l1Header))
    proxy = (?abiDecode(gameOut, (uint32, uint64, Address)))[2]

    # get the root claim of the latest game
    rootOut = ?(await l1Engine.makeCall(proxy, hashFnSig("rootClaim()"), l1Header))
    outputRoot = (?abiDecode(rootOut, array[32, byte])).to(Hash32)

    # get the block number for the latest game
    l2nOut = ?(await l1Engine.makeCall(proxy, hashFnSig("l2BlockNumber()"), l1Header))
    l2Number = base.BlockNumber((?abiDecode(l2nOut, UInt256)).truncate(uint64))

  ok(L1OutputProposal(outputRoot: outputRoot, l2BlockNumber: l2Number))

# this gives us the latest finalized output root
proc readAnchorRoot*(
    l1Engine: RpcVerificationEngine, anchorRegistryContract: Address, l1Header: Header
): Future[EngineResult[L1OutputProposal]] {.async: (raises: [CancelledError]).} =
  let
    out0 = ?(
      await l1Engine.makeCall(
        anchorRegistryContract, hashFnSig("getAnchorRoot()"), l1Header
      )
    )
    decoded = ?abiDecode(out0, (array[32, byte], UInt256))
    outputRoot = decoded[0].to(Hash32)
    l2Number = base.BlockNumber(decoded[1].truncate(uint64))

  ok(L1OutputProposal(outputRoot: outputRoot, l2BlockNumber: l2Number))
