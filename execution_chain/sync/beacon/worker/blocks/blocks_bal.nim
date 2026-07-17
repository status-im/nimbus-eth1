# Nimbus
# Copyright (c) 2026 Status Research & Development GmbH
# Licensed and distributed under either of
#   * MIT license (license terms in the root directory or at
#     https://opensource.org/licenses/MIT).
#   * Apache v2 license (license terms in the root directory or at
#     https://www.apache.org/licenses/LICENSE-2.0).
# at your option. This file may not be copied, modified, or distributed
# except according to those terms.

{.push raises:[].}

import
  std/typetraits,
  chronos, 
  results,
  eth/common,
  ../../../wire_protocol,
  ../worker_desc

export block_access_lists

# ------------------------------------------------------------------------------
# Public functions
# ------------------------------------------------------------------------------

proc fetchRawBlockAccessLists*(
    buddy: BeaconPeerRef;
    request: BlockAccessListsRequest;
      ): Future[Opt[seq[RawBlockAccessList]]]
      {.async: (raises: []).} =
  ## Request the raw (RLP-encoded) block access lists (EIP-7928) for the block
  ## hashes in `request` from the sync peer.
  ##
  ## The peer serves the lists in request order but truncates its response at a
  ## soft size limit (and a maximum count), so a single response may cover only
  ## a prefix of the requested hashes. Follow-up requests are issued for the
  ## remaining hashes until all are received (or the peer stops making
  ## progress), so the returned sequence is aligned by index with
  ## `request.blockHashes`.

  if not buddy.peer.supports(eth71):
    return Opt.none(seq[RawBlockAccessList])

  let nReq = request.blockHashes.len
  if nReq == 0:
    return Opt.some(newSeq[RawBlockAccessList](0))

  var accessLists = newSeqOfCap[RawBlockAccessList](nReq)
  try:
    while accessLists.len < nReq:
      # Request only the hashes not yet served by previous responses.
      let remaining = BlockAccessListsRequest(
        blockHashes: request.blockHashes[accessLists.len ..< nReq])
      let resp = (await buddy.peer.getBlockAccessLists(
        remaining, fetchBalsRlpxTimeout)).valueOr:
          return Opt.none(seq[RawBlockAccessList])
      if resp.accessLists.len == 0:
        break               # peer served nothing; avoid looping indefinitely
      accessLists.add resp.accessLists
  except CancelledError:
    return Opt.none(seq[RawBlockAccessList])
  except CatchableError:
    return Opt.none(seq[RawBlockAccessList])

  Opt.some(accessLists)

proc decodeBlockAccessList*(
    raw: RawBlockAccessList;
    header: Header;
      ): Opt[BlockAccessListRef] =
  ## Decode a single raw (RLP-encoded) block access list received from a peer
  ## and verify it against the BAL hash committed in the block header.
  ## Returns `none` when the peer reported the list as unavailable, when it is
  ## malformed, or when its hash does not match the header. 
  let bytes = distinctBase(raw)

  if bytes.len == 0 or (bytes.len == 1 and bytes[0] == 0x80'u8):
    return Opt.none(BlockAccessListRef)

  let expectedHash = header.blockAccessListHash.valueOr:
    return Opt.none(BlockAccessListRef)

  if keccak256(bytes) != expectedHash:
    return Opt.none(BlockAccessListRef)

  let bal: BlockAccessListRef = new BlockAccessList
  bal[] = BlockAccessList.decode(bytes).valueOr:
    return Opt.none(BlockAccessListRef)

  Opt.some(bal)

# ------------------------------------------------------------------------------
# End
# ------------------------------------------------------------------------------
