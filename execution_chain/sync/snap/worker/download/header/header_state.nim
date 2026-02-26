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
  std/[os, strutils],
  pkg/[chronicles, chronos],
  ../../[mpt, worker_desc],
  ./header_fetch

logScope:
  topics = "snap sync"

# ------------------------------------------------------------------------------
# Private function
# ------------------------------------------------------------------------------

template headerStateRegister(
    buddy: SnapPeerRef;
    blockNumber: BlockNumber;
    info: static[string];
      ): Result[StateRoot,bool] =
  ## Async/template
  ##
  ## Set new state root relative to argument block number. There is no
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
    let ctx = buddy.ctx

    if blockNumber == 0:
      break body # error

    ctx.pool.stateDB.get(blockNumber).isErrOr:
      bodyRc = Result[StateRoot,bool].err(false)
      break body # no change

    let
      header = buddy.headerFetch(blockNumber).valueOr:
        break body # error
      root = StateRoot(header.stateRoot)
      hash = BlockHash(header.computeBlockHash)

    # Store root -> block data mapping
    ctx.pool.mptAsm.putBlockData(root, hash, blockNumber).isOkOr:
      trace info & ": Cannot store state root map", peer,
        stateRoot=root.toStr, blockHash=hash.toStr, blockNumber
      break body # error

    ctx.pool.stateDB.register(header, hash)
    bodyRc = Result[StateRoot,bool].ok(root)

  bodyRc # return

proc readData(
    buddy: SnapPeerRef;
    fileName: string;
    info: static[string];
      ): Opt[string] =
  let peer {.inject,used.} = $buddy.peer            # logging only

  var file: File
  if not file.open(fileName):
    trace info & ": Cannot open file", peer, fileName
    return err()
  defer: file.close()

  var lns: seq[string]
  try:
    lns = file.readAll.splitLines()
  except IOError:
    trace info & ": Read error", peer, fileName
    return err()

  if lns.len == 0 or lns[0].len == 0:
    trace info & ": Empty file", peer, fileName
    return err()

  let data = lns[0].strip
  if 66 < data.len: # max: 2 + 64
    trace info & ": Data contents too large", peer, fileName, data
    return err()

  ok(data)

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
      trace info & ": Cannot store state root map", peer,
        stateRoot=root.toStr, blockHash=hash.toStr, blockNumber
      break body # error

    ctx.pool.stateDB.register(header, hash)
    bodyRc = Result[StateRoot,bool].ok(root)

  bodyRc # return

# ------------------------------------------------------------------------------
# Public test/debugging function(s)
# ------------------------------------------------------------------------------

template headerStateLoad*(
    buddy: SnapPeerRef;
    fName: string;
    info: static[string];
      ): Result[StateRoot,bool] =
  ## Async/template
  ##
  ## Set/update account state from file
  ##
  # Provide template-ready function body
  var bodyRc = Result[StateRoot,bool].err(false)    # defaults to: no change
  block body:
    if fName.len == 0 or not fName.fileExists:
      break body # no change

    let
      ctx = buddy.ctx
      peer {.inject,used.} = $buddy.peer            # logging only
      fileName {.inject.} = fName

    let data {.inject.} = buddy.readData(fileName, info).valueOr:
      bodyRc = Result[StateRoot,bool].err(true)
      break body # error

    # Don't ask twice for the same contents
    if data == ctx.pool.stateUpdateChecked:
       break body # no change

    block parseAndUpdate:
      if 64 <= data.len:
        # Try target selection by block hash
        try:
          let blkHash = BlockHash(Hash32.fromHex(data))
          if blkHash != BlockHash(zeroHash32):
            bodyRc = buddy.headerStateRegister(blkHash, info)
            if bodyRc.isErr() and bodyRc.error():
              trace info & ": State update failed", peer, fileName,
                blockHash=blkHash.toStr
          break parseAndUpdate
        except ValueError:
          discard

      else:
        # Try target selection by block number
        try:
          let number = data.parseUInt.uint64
          if 0 < number:
            bodyRc = buddy.headerStateRegister(number, info)
            if bodyRc.isErr() and bodyRc.error():
              trace info & ": State update failed", peer, fileName,
                blockNumber=number
          break parseAndUpdate
        except ValueError:
          discard

      trace info & ": Parse error", peer, fileName, data
      bodyRc = Result[StateRoot,bool].err(true)
      # End block `parseAndUpdate`

    if bodyRc.isOk() or not bodyRc.error():
      ctx.pool.stateUpdateChecked = data
    # End block `body`

  bodyRc # return

# ------------------------------------------------------------------------------
# End
# ------------------------------------------------------------------------------
