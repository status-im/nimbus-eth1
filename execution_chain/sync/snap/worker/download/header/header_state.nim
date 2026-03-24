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
  ../../[mpt, worker_desc],
  ./header_fetch

logScope:
  topics = "snap sync"

# ------------------------------------------------------------------------------
# Public function(s)
# ------------------------------------------------------------------------------

template headerStateRegister*(
    buddy: SnapPeerRef;
    hash: BlockHash;
    info: static[string];
      ): Result[StateRoot,bool] =
  ## Async/template
  ##
  ## Set new state root relative to argument block hash.There is no
  ## guarantee that the block header fetched from the network belongs to
  ## a canonical chain.
  ##
  ## Meaning of return codes:
  ## * ok(StateRoot) -- updated
  ## * err(false)    -- no change
  ## * err(true)     -- error
  ##
  var bodyRc = Result[StateRoot,bool].err(true) # defaults to: error
  block body:
    if hash == BlockHash(zeroHash32):
      break body # no change

    let ctx = buddy.ctx
    ctx.pool.stateDB.get(hash).isErrOr:
      bodyRc = Result[StateRoot,bool].err(false)
      break body # no change

    let
      header = buddy.headerFetch(hash).valueOr:
        break body # error
      root = StateRoot(header.stateRoot)
      blockNumber = header.number

    if blockNumber == 0:
      break body # error

    # Store root -> block data mapping
    ctx.pool.mptAsm.putBlockData(root, hash, blockNumber).isOkOr:
      trace info & ": Cannot store state root map", peer=buddy.peer,
        stateRoot=root.toStr, blockHash=hash.toStr, blockNumber
      break body # error

    ctx.pool.stateDB.register(header, hash, info)
    bodyRc = Result[StateRoot,bool].ok(root)

  bodyRc # return

# ------------------------------------------------------------------------------
# End
# ------------------------------------------------------------------------------
