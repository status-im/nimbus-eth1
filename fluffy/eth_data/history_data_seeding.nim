# # Nimbus - Portal Network
# # Copyright (c) 2022-2024 Status Research & Development GmbH
# # Licensed and distributed under either of
# #   * MIT license (license terms in the root directory or at https://opensource.org/licenses/MIT).
# #   * Apache v2 license (license terms in the root directory or at https://www.apache.org/licenses/LICENSE-2.0).
# # at your option. This file may not be copied, modified, or distributed except according to those terms.

{.push raises: [].}

import
  results,
  chronos,
  chronicles,
  ../network/wire/portal_protocol,
  ../network/history/
    [history_content, history_network, validation/historical_hashes_accumulator],
  "."/[era1, history_data_ssz_e2s]

from eth/common/eth_types_rlp import rlpHash

export results

##
## Era1 based iterators that encode to Portal content
##

# Note: these iterators + the era1 iterators will assert on error. These asserts
# would indicate corrupt/invalid era1 files. We might want to instead break,
# raise an exception or return a Result type instead, but the latter does not
# have great support for usage in iterators.

iterator headersWithProof*(
    f: Era1File, epochRecord: EpochRecordCached
): (ContentKeyByteList, seq[byte]) =
  for blockHeader in f.era1BlockHeaders:
    doAssert blockHeader.isPreMerge()

    let
      contentKey = ContentKey(
        contentType: ContentType.blockHeader,
        blockHeaderKey: BlockKey(blockHash: blockHeader.rlpHash()),
      ).encode()

      headerWithProof = buildHeaderWithProof(blockHeader, epochRecord).valueOr:
        raiseAssert "Failed to build header with proof: " & $blockHeader.number

      contentValue = SSZ.encode(headerWithProof)

    yield (contentKey, contentValue)

iterator blockContent*(f: Era1File): (ContentKeyByteList, seq[byte]) =
  for (header, body, receipts, _) in f.era1BlockTuples:
    let blockHash = header.rlpHash()

    block: # block body
      let
        contentKey = ContentKey(
          contentType: blockBody, blockBodyKey: BlockKey(blockHash: blockHash)
        ).encode()

        contentValue = encode(body)

      yield (contentKey, contentValue)

    block: # receipts
      let
        contentKey = ContentKey(
          contentType: ContentType.receipts, receiptsKey: BlockKey(blockHash: blockHash)
        ).encode()

        contentValue = encode(receipts)

      yield (contentKey, contentValue)

##
## Era1 based Gossip calls
##

proc historyGossipHeadersWithProof*(
    p: PortalProtocol, era1File: string, epochRecordFile: Opt[string], verifyEra = false
): Future[Result[void, string]] {.async.} =
  let f = ?Era1File.open(era1File)

  if verifyEra:
    let _ = ?f.verify()

  # Note: building the accumulator takes about 150ms vs 10ms for reading it,
  # so it is probably not really worth using the read version considering the
  # UX hassle it adds to provide the accumulator ssz files.
  let epochRecord =
    if epochRecordFile.isNone:
      ?f.buildAccumulator()
    else:
      ?readEpochRecordCached(epochRecordFile.get())

  for (contentKey, contentValue) in f.headersWithProof(epochRecord):
    let peers = await p.neighborhoodGossip(
      Opt.none(NodeId), ContentKeysList(@[contentKey]), @[contentValue]
    )
    info "Gossiped block header", contentKey, peers

  ok()

proc historyGossipBlockContent*(
    p: PortalProtocol, era1File: string, verifyEra = false
): Future[Result[void, string]] {.async.} =
  let f = ?Era1File.open(era1File)

  if verifyEra:
    let _ = ?f.verify()

  for (contentKey, contentValue) in f.blockContent():
    let peers = await p.neighborhoodGossip(
      Opt.none(NodeId), ContentKeysList(@[contentKey]), @[contentValue]
    )
    info "Gossiped block content", contentKey, peers

  ok()
