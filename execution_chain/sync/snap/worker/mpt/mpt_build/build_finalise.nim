# Nimbus
# Copyright (c) 2026 Status Research & Development GmbH
# Licensed under either of
#  * Apache License, version 2.0, ([LICENSE-APACHE](LICENSE-APACHE))
#  * MIT license ([LICENSE-MIT](LICENSE-MIT))
# at your option.
# This file may not be copied, modified, or distributed except according to
# those terms.

{.push raises: [].}

import
  std/[tables, typetraits],
  pkg/eth/trie/nibbles,
  ../../../../wire_protocol/snap/snap_types,
  ../../state_db,
  ./build_desc

# ------------------------------------------------------------------------------
# Private functions, recursive finalisation helpers
# ------------------------------------------------------------------------------

{.push checks: off, optimization: speed, raises: [].}

template reKeyWalkerLeaf(node: LeafNodeRef) =
  var wrt = initRlpList 2
  wrt.append @(node.lfPfx.toHexPrefix(true).data())
  wrt.append node.lfPayload
  node.lfData = wrt.finish()
  node.selfKey = node.lfData.digestToOrPlain(HashKey)

proc reKeyWalkerBranch(node: var BranchNodeRef) =
  var wrt = initRlpList 17
  for n in 0 .. 15:
    if node.brLinks[n].isNil:
      wrt.append ""
    else:
      # Note that the recursion is exhaustive as the sub-tree
      # is always a complete MPT (i.e. no dead links)
      if node.brLinks[n].kind == Leaf:
        LeafNodeRef(node.brLinks[n]).reKeyWalkerLeaf()
      else:
        BranchNodeRef(node.brLinks[n]).reKeyWalkerBranch()
      wrt.append node.brLinks[n].selfKey
  wrt.append ""
  node.brData = wrt.finish()
  node.selfKey = node.brData.digestTo(HashKey)

  if 0 < node.xtPfx.len:
    node.selfKey.swap node.brKey
    wrt = initRlpList 2
    wrt.append @(node.xtPfx.toHexPrefix(false).data())
    wrt.append node.brKey
    node.xtData = wrt.finish()
    node.selfKey = node.xtData.digestTo(HashKey)

template reKeyWalkerSub(stop: StopNodeRef) =
  ## Recursively calculate and stote rlp-data and node keys for sub-MPT
  doAssert not stop.isNil
  if stop.sub.kind == Branch:
    BranchNodeRef(stop.sub).reKeyWalkerBranch()
  else:
    LeafNodeRef(stop.sub).reKeyWalkerLeaf()

{.pop.}

# ------------------------------------------------------------------------------
# Public functions
# ------------------------------------------------------------------------------

proc finalise*(db: NodeTrieRef): uint =
  ## Finalise an MPT.
  ##
  ## Recusively calculate missing node keys and merge complete sub-MPT
  ## into the already locked and finished part of the MPT.
  ##
  ## The function returns the number of sub-MPT resolved (see also
  ## function `isComplete()`.
  ##
  ## Note: This function can savely be called any time while merging (see
  ##  `merge()`) is still ongoing. It is only inefficient because
  ##   non-finalised sub-MPTs need to be visited, again.
  ##
  var
    resolved = newSeqUninit[HashKey](db.stops.len)
    resLen = 0
  for (key,stopNode) in db.stops.pairs:
    if not stopNode.sub.isNil:
      stopNode.reKeyWalkerSub()

      if stopNode.sub.selfKey == stopNode.selfKey:
        # Join with pre-set part, this locks this sub-tree
        if stopNode.parent.isNil:
          db.root = stopNode.sub
        else:
          BranchNodeRef(stopNode.parent).brLinks[stopNode.inx] = stopNode.sub
        resolved[resLen] = key
        resLen.inc

  if db.stops.len <= resLen:                        # check whether all done
    db.stops.clear                                  # clear all at once
  else:
    for n in 0 ..< resLen:                          # keep remaining sub-MPTs
      db.stops.del resolved[n]

  resLen.uint                                       # return value

proc finalised*(db: NodeTrieRef): Opt[HashKey] =
  ## Finalise MPT and return the state root. This function will not verify
  ## whether the state root of the sub-MPT matches the registered key at the
  ## stop node.
  ##
  ## Note that this function requires the MPT to be initialised without proof
  ## nodes (see `init()` functions.)
  ##
  db.stops.withValue(db.root.selfKey, stop):
    if not stop.sub.isNil:
      stop[].reKeyWalkerSub()
      return ok(stop.sub.selfKey)
  err()

# ------------------------------------------------------------------------------
# End
# ------------------------------------------------------------------------------
