# Nimbus
# Copyright (c) 2025-2026 Status Research & Development GmbH
# Licensed under either of
#  * Apache License, version 2.0, ([LICENSE-APACHE](LICENSE-APACHE) or
#    http://www.apache.org/licenses/LICENSE-2.0)
#  * MIT license ([LICENSE-MIT](LICENSE-MIT) or
#    http://opensource.org/licenses/MIT)
# at your option. This file may not be copied, modified, or distributed
# except according to those terms.

{.push raises: [].}

import
  pkg/[chronicles, chronos],
  ../../../core/chain/forked_chain,
  ../../../utils/utils,
  ../eth/[eth_broadcast, eth_handler],
  ./[snap_trace_config, snap_types]

logScope:
  topics = "snap wire"

# ------------------------------------------------------------------------------
# Public constructor/destructor
# ------------------------------------------------------------------------------

proc new*(T: type SnapWireStateRef; chain: ForkedChainRef): T =
  T(chain: chain)

# ------------------------------------------------------------------------------
# Public functions: snap wire protocol handlers
# ------------------------------------------------------------------------------

proc getAccountRange*(
    ctx: SnapWireStateRef;
    req: AccountRangeRequest;
      ): Opt[AccountRangePacket] =
  when trSnapTraceHandlerOk:
    trace "getAccountRange: not implemented",
      rootHash      = req.rootHash.short,
      startingHash  = req.startingHash.short,
      limitHash     = req.limitHash.short,
      responseBytes = req.responseBytes
  err()

proc getStorageRanges*(
    ctx: SnapWireStateRef;
    req: StorageRangesRequest;
      ): Opt[StorageRangesPacket] =
  when trSnapTraceHandlerOk:
    trace "getStorageRanges: not implemented",
      rootHash       = req.rootHash.short,
      accountHashes  = (if req.accountHashes.len == 0: "n/a"
                        else: "[" & req.accountHashes[0].short & ",..]"),
      nAccountHashes = req.accountHashes.len,
      startingHash   = req.startingHash.to(Hash32).short,
      limitHash      = req.limitHash.to(Hash32).short,
      responseBytes  = req.responseBytes
  err()

proc getByteCodes*(
   ctx: SnapWireStateRef;
   req: ByteCodesRequest;
     ): Opt[ByteCodesPacket] =
  when trSnapTraceHandlerOk:
    trace "getByteCodes: not implemented",
      hashes = (if req.hashes.len == 0: "n/a"
                else: "[" & req.hashes[0].short & ",..]"),
      bytes  = req.bytes
  err()

proc getTrieNodes*(
   ctx: SnapWireStateRef;
   req: TrieNodesRequest;
     ): Opt[TrieNodesPacket] =
  when trSnapTraceHandlerOk:
    trace "getTrieNodes: not implemented",
      rootHash = req.rootHash.short,
      paths    = (if req.paths.len == 0: "n/a"
                  else: "[#" & $req.paths[0].len & ",..]"),
      nPaths   = req.paths.len,
      bytes    = req.bytes
  err()

proc getBlockAccessLists*(
    ctx: SnapWireStateRef;
    req: SnapBalRequest;
      ): Opt[BlockAccessListsPacket] =
  ## Same response as `eth/71` `GetBlockAccessLists`
  let softLimit = min(req.bytes, SOFT_RESPONSE_LIMIT.uint64).int
  when trSnapTraceHandlerOk:
    trace "getBlockAccessLists", nReq=req.blockHashes.len, softLimit
  ok(ctx.chain.getBlockAccessLists(req.blockHashes, softLimit))

# ------------------------------------------------------------------------------
# End
# ------------------------------------------------------------------------------
