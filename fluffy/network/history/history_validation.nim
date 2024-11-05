# Fluffy
# Copyright (c) 2021-2024 Status Research & Development GmbH
# Licensed and distributed under either of
#   * MIT license (license terms in the root directory or at https://opensource.org/licenses/MIT).
#   * Apache v2 license (license terms in the root directory or at https://www.apache.org/licenses/LICENSE-2.0).
# at your option. This file may not be copied, modified, or distributed except according to those terms.

{.push raises: [].}

import
  chronos/timer,
  eth/trie/ordered_trie,
  ../../network_metadata,
  ./history_type_conversions,
  ./validation/historical_hashes_accumulator

from eth/common/eth_types_rlp import rlpHash

export historical_hashes_accumulator

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
  # No additional quick-checks are addedhere such as timestamp vs the optional
  # (later forks) added fields. E.g. Shanghai field, Cancun fields,
  # zero ommersHash, etc.
  # This is because the block hash comparison + canonical verification will
  # catch these. For comparison by number this is will also be caught by the
  # canonical verification.
  let header = ?decodeRlp(bytes, Header)

  ?header.validateHeader(id)

  ok(header)

func verifyBlockHeaderProof*(
    a: FinishedHistoricalHashesAccumulator, header: Header, proof: BlockHeaderProof
): Result[void, string] =
  case proof.proofType
  of BlockHeaderProofType.historicalHashesAccumulatorProof:
    a.verifyAccumulatorProof(header, proof.historicalHashesAccumulatorProof)
  of BlockHeaderProofType.none:
    if header.isPreMerge():
      err("Pre merge header requires HistoricalHashesAccumulatorProof")
    else:
      # TODO:
      # Add verification post merge based on historical_roots & historical_summaries
      ok()

func validateCanonicalHeaderBytes*(
    bytes: openArray[byte], id: uint64 | Hash32, a: FinishedHistoricalHashesAccumulator
): Result[Header, string] =
  let headerWithProof = decodeSsz(bytes, BlockHeaderWithProof).valueOr:
    return err("Failed decoding header with proof: " & error)
  let header = ?validateHeaderBytes(headerWithProof.header.asSeq(), id)

  ?a.verifyBlockHeaderProof(header, headerWithProof.proof)

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
