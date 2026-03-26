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
      ): Result[StateDataRef,ErrorType] =
  ## Async/template
  ##
  ## Set new state root relative to argument block hash.There is no
  ## guarantee that the block header fetched from the network belongs to
  ## a canonical chain.
  ##
  ## Simultaneous download is blocked by allowing download of one particular
  ## header while others get a lock error after some timeout. If the lock
  ## resolves before the timeout, the header state is fetched from the registry.
  ##
  var bodyRc = Result[StateDataRef,ErrorType].err(ELockError)
  block body:
    let
      ctx = buddy.ctx
      sdb = ctx.pool.stateDB

    if hash in ctx.pool.lockedHeader:
      # Wait for the lock to be released, then take state from registry
      const timeout = fetchHeaderRlpxTimeout + chronos.seconds(2)
      let start = Moment.now()
      while true:
        try:
          await sleepAsync lockWaitPollingTime
          if hash notin ctx.pool.lockedHeader:      # lock was released
            sdb.get(hash).isErrOr:                  # get from registry (if any)
              bodyRc = Result[StateDataRef,ErrorType].ok(value)
            break body
          if timeout < Moment.now() - start:        # check for timeout
            break                                   # => break while
        except CancelledError:
          break                                     # => break while
        # End while

      break body                                    # come back later
      # End `if locked`

    # Lock item and fetch (via `async` template)
    ctx.pool.lockedHeader.incl hash                 # lock it for downloading
    let rc = buddy.headerFetch(hash)                # fetch header
    ctx.pool.lockedHeader.excl hash                 # unlock

    if rc.isErr:
      bodyRc = Result[StateDataRef,ErrorType].err(rc.error)
      break body                                    # come back later

    let
      root = StateRoot(rc.value.stateRoot)
      blockNumber = rc.value.number

    # Store root -> block data mapping
    ctx.pool.mptAsm.putBlockData(root, hash, blockNumber).isOkOr:
      trace info & ": Cannot store state root map", peer=buddy.peer,
        stateRoot=root.toStr, blockHash=hash.toStr, blockNumber
      bodyRc = Result[StateDataRef,ErrorType].err(ETrieError)
      break body                                    # error

    bodyRc = Result[StateDataRef,ErrorType].ok(
      sdb.register(root, hash, blockNumber, info))

  bodyRc # return

# ------------------------------------------------------------------------------
# End
# ------------------------------------------------------------------------------
