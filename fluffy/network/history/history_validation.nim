# Fluffy
# Copyright (c) 2021-2025 Status Research & Development GmbH
# Licensed and distributed under either of
#   * MIT license (license terms in the root directory or at https://opensource.org/licenses/MIT).
#   * Apache v2 license (license terms in the root directory or at https://www.apache.org/licenses/LICENSE-2.0).
# at your option. This file may not be copied, modified, or distributed except according to those terms.

{.push raises: [].}

import
  chronos/timer,
  eth/trie/ordered_trie,
  beacon_chain/spec/presets,
  ../../network_metadata,
  ./history_type_conversions,
  ./validation/[
    historical_hashes_accumulator, block_proof_historical_roots,
    block_proof_historical_summaries,
  ]

from eth/common/eth_types_rlp import rlpHash

export historical_hashes_accumulator

type HistoryAccumulators* = object
  historicalHashes*: FinishedHistoricalHashesAccumulator
  historicalRoots*: HistoricalRoots
  historicalSummaries*: HistoricalSummaries

func validateHeader(header: Header, blockHash: Hash32): Result[void, string] =
  if not (header.rlpHash() == blockHash):
    err("Header hash does not match")
  else:
    ok()

func validateHeader(header: Header, number: uint64): Result[void, string] =
  if not (header.number == number):
    err("Header number does not match")
  else:
    ok()

func validateHeaderBytes*(
    bytes: openArray[byte], id: uint64 | Hash32
): Result[Header, string] =
  # Note:
  # No additional quick-checks are added here such as timestamp vs the optional
  # (per hardfork) added fields. E.g. Shanghai field, Cancun fields,
  # zero ommersHash, etc.
  # This is because the block hash comparison + canonical verification will
  # catch these. For comparison by number this will be caught by the
  # canonical verification.
  # The hash or number verification does still need to be done because else
  # it would only be verified that a header is canonical and not that the
  # returned header is the one that was requested.
  let header = ?decodeRlp(bytes, Header)

  ?header.validateHeader(id)

  ok(header)

func verifyBlockHeaderProof*(
    a: HistoryAccumulators,
    header: Header,
    proof: ByteList[MAX_HEADER_PROOF_LENGTH],
    cfg: RuntimeConfig,
): Result[void, string] =
  let timestamp = Moment.init(header.timestamp.int64, Second)

  if isShanghai(chainConfig, timestamp):
    # Note: currently disabled
    # - No effective means to get historical summaries yet over the network
    # - Proof is currently not as per spec, as we prefer to use SSZ Vectors

    # let proof = decodeSsz(proof.asSeq(), BlockProofHistoricalSummaries).valueOr:
    #   return err("Failed decoding historical_summaries based block proof: " & error)

    # if a.historicalSummaries.verifyProof(
    #   proof, Digest(data: header.rlpHash().data), cfg
    # ):
    #   ok()
    # else:
    #   err("Block proof verification failed (historical_summaries)")
    err("Shanghai block proof verification not yet activated")
  elif isPoSBlock(chainConfig, header.number):
    let proof = decodeSsz(proof.asSeq(), BlockProofHistoricalRoots).valueOr:
      return err("Failed decoding historical_roots based block proof: " & error)

    if a.historicalRoots.verifyProof(proof, Digest(data: header.rlpHash().data)):
      ok()
    else:
      err("Block proof verification failed (historical roots)")
  else:
    let accumulatorProof = decodeSsz(proof.asSeq(), HistoricalHashesAccumulatorProof).valueOr:
      return
        err("Failed decoding historical hashes accumulator based block proof: " & error)

    if a.historicalHashes.verifyProof(header, accumulatorProof):
      ok()
    else:
      err("Block proof verification failed (historical hashes accumulator)")

func validateCanonicalHeaderBytes*(
    bytes: openArray[byte],
    id: uint64 | Hash32,
    accumulators: HistoryAccumulators,
    cfg: RuntimeConfig,
): Result[Header, string] =
  let headerWithProof = decodeSsz(bytes, BlockHeaderWithProof).valueOr:
    return err("Failed decoding header with proof: " & error)
  let header = ?validateHeaderBytes(headerWithProof.header.asSeq(), id)

  ?accumulators.verifyBlockHeaderProof(header, headerWithProof.proof, cfg)

  ok(header)

func validateBlockBody*(
    body: PortalBlockBodyLegacy, header: Header
): Result[void, string] =
  ## Validate the block body against the txRoot and ommersHash from the header.
  let calculatedOmmersHash = keccak256(body.uncles.asSeq())
  if calculatedOmmersHash != header.ommersHash:
    return err("Invalid ommers hash")

  let calculatedTxsRoot = orderedTrieRoot(body.transactions.asSeq)
  if calculatedTxsRoot != header.txRoot:
    return err(
      "Invalid transactions root: expected " & $header.txRoot & " - got " &
        $calculatedTxsRoot
    )

  ok()

func validateBlockBody*(
    body: PortalBlockBodyShanghai, header: Header
): Result[void, string] =
  ## Validate the block body against the txRoot, ommersHash and withdrawalsRoot
  ## from the header.
  # Shortcut the ommersHash calculation as uncles must be an RLP encoded
  # empty list
  if body.uncles.asSeq() != @[byte 0xc0]:
    return err("Invalid ommers hash, uncles list is not empty")

  let calculatedTxsRoot = orderedTrieRoot(body.transactions.asSeq)
  if calculatedTxsRoot != header.txRoot:
    return err(
      "Invalid transactions root: expected " & $header.txRoot & " - got " &
        $calculatedTxsRoot
    )

  # TODO: This check is done higher up but perhaps this can become cleaner with
  # some refactor.
  doAssert(header.withdrawalsRoot.isSome())

  let
    calculatedWithdrawalsRoot = orderedTrieRoot(body.withdrawals.asSeq)
    headerWithdrawalsRoot = header.withdrawalsRoot.get()
  if calculatedWithdrawalsRoot != headerWithdrawalsRoot:
    return err(
      "Invalid withdrawals root: expected " & $headerWithdrawalsRoot & " - got " &
        $calculatedWithdrawalsRoot
    )

  ok()

func validateBlockBodyBytes*(
    bytes: openArray[byte], header: Header
): Result[BlockBody, string] =
  ## Fully decode the SSZ encoded Portal Block Body and validate it against the
  ## header.
  ## TODO: improve this decoding in combination with the block body validation
  ## calls.
  let timestamp = Moment.init(header.timestamp.int64, Second)
  # TODO: The additional header checks are not needed as header is implicitly
  # verified by means of the accumulator? Except that we don't use this yet
  # post merge, so the checks are still useful, for now.
  if isShanghai(chainConfig, timestamp):
    if header.withdrawalsRoot.isNone():
      err("Expected withdrawalsRoot for Shanghai block")
    elif header.ommersHash != EMPTY_UNCLE_HASH:
      err("Expected empty uncles for a Shanghai block")
    else:
      let body = ?decodeSsz(bytes, PortalBlockBodyShanghai)
      ?validateBlockBody(body, header)
      BlockBody.fromPortalBlockBody(body)
  elif isPoSBlock(chainConfig, header.number):
    if header.withdrawalsRoot.isSome():
      err("Expected no withdrawalsRoot for pre Shanghai block")
    elif header.ommersHash != EMPTY_UNCLE_HASH:
      err("Expected empty uncles for a PoS block")
    else:
      let body = ?decodeSsz(bytes, PortalBlockBodyLegacy)
      ?validateBlockBody(body, header)
      BlockBody.fromPortalBlockBody(body)
  else:
    if header.withdrawalsRoot.isSome():
      err("Expected no withdrawalsRoot for pre Shanghai block")
    else:
      let body = ?decodeSsz(bytes, PortalBlockBodyLegacy)
      ?validateBlockBody(body, header)
      BlockBody.fromPortalBlockBody(body)

func validateReceipts*(
    receipts: PortalReceipts, receiptsRoot: Hash32
): Result[void, string] =
  if orderedTrieRoot(receipts.asSeq) != receiptsRoot:
    err("Unexpected receipt root")
  else:
    ok()

func validateReceiptsBytes*(
    bytes: openArray[byte], receiptsRoot: Hash32
): Result[seq[Receipt], string] =
  ## Fully decode the SSZ encoded receipts and validate it against the header's
  ## receipts root.
  let receipts = ?decodeSsz(bytes, PortalReceipts)

  ?validateReceipts(receipts, receiptsRoot)

  seq[Receipt].fromPortalReceipts(receipts)
