# Nimbus - Types, data structures and shared utilities used in network sync
#
# Copyright (c) 2018-2021 Status Research & Development GmbH
# Licensed under either of
#  * Apache License, version 2.0, ([LICENSE-APACHE](LICENSE-APACHE) or
#    http://www.apache.org/licenses/LICENSE-2.0)
#  * MIT license ([LICENSE-MIT](LICENSE-MIT) or
#    http://opensource.org/licenses/MIT)
# at your option. This file may not be copied, modified, or
# distributed except according to those terms.

## Aristo (aka Patricia) DB records merge test

import
  eth/common,
  unittest2,
  ../../nimbus/db/kvstore_rocksdb,
  ../../nimbus/db/aristo/[
    aristo_desc, aristo_debug, aristo_error, aristo_hike,
    aristo_merge, aristo_transcode],
  ../../nimbus/sync/snap/range_desc,
  ../replay/undump_accounts,
  ./test_helpers

# ------------------------------------------------------------------------------
# Private helpers
# ------------------------------------------------------------------------------

# ------------------------------------------------------------------------------
# Public test function
# ------------------------------------------------------------------------------

proc test_mergeAccounts*(
    noisy: bool;
    lst: openArray[PackedAccountRange];
      ) =
  for u,par in lst:
    let db = AristoDbRef()
    var
      root = VertexID(0)
      count = 0

    for n,w in par.accounts:
      let
        sTabState = db.sTab.pp(db)
        payload = PayloadRef(pType: BlobData, blob:  w.accBlob)
        pathTag = w.accKey.to(NodeTag)
        hike = db.merge(pathTag, payload, root, proofMode=false)
        ekih = pathTag.hikeUp(hike.root, db)

      if hike.error == AristoError(0):
        root = hike.root

      count = n
      if hike.error != AristoError(0): # or true:
        noisy.say "***", "<", n, "> ", pathTag.pp,
          "\n   hike",
          "\n    ", hike.pp(db),
          "\n   sTab (prev)",
          "\n    ", sTabState,
          "\n   sTab",
          "\n    ", db.sTab.pp(db),
          "\n   lTab",
          "\n    ", db.lTab.pp,
          "\n"

      check hike.error == AristoError(0)
      check ekih.error == AristoError(0)

      if ekih.legs.len == 0:
        check 0 < ekih.legs.len
      elif ekih.legs[^1].wp.vtx.vType != Leaf:
        check ekih.legs[^1].wp.vtx.vType == Leaf
      else:
        check ekih.legs[^1].wp.vtx.lData.blob == w.accBlob

      if db.lTab.len != n + 1:
        check db.lTab.len == n + 1 # quick leaf access table
        break                      # makes no sense to go on further

    noisy.say "***", "sample ", u, "/", lst.len ," leafs merged: ", count+1


proc test_mergeProofsAndAccounts*(
    noisy: bool;
    lst: openArray[UndumpAccounts];
      ) =
  for u,par in lst:
    let
      db = AristoDbRef()
      rootKey = par.root.to(NodeKey)
    var
      rootID: VertexID
      count = 0

    for n,w in par.data.proof:
      let
        key = w.Blob.digestTo(NodeKey)
        node = w.Blob.decode(NodeRef)
        rc = db.merge(key, node)
      if rc.isErr:
        check rc.isOK # provoke message and error
        check rc.error == AristoError(0)
        continue

      check n + 1 < db.pAmk.len
      check n + 1 < db.kMap.len
      check db.sTab.len == n + 1

    # Set up root ID
    db.pAmk.withValue(rootKey, vidPtr):
      rootID = vidPtr[]

    check not rootID.isZero

    if true and false:
      noisy.say "***",  count, " proof nodes, root=", rootID.pp,
        #"\n   pAmk",
        #"\n    ", db.pAmk.pp(db),
        "\n   kMap",
        "\n    ", db.kMap.pp(db),
        "\n   sTab",
        "\n    ", db.sTab.pp(db),
        "\n"

    for n,w in par.data.accounts:
      let
        sTabState = db.sTab.pp(db)
        payload = PayloadRef(pType: BlobData, blob:  w.accBlob)
        pathTag = w.accKey.to(NodeTag)
        hike = db.merge(pathTag, payload, rootID, proofMode=true) #, noisy=true)
        ekih = pathTag.hikeUp(rootID, db)

      count = n
      if hike.error != AristoError(0): # or true:
        noisy.say "***", "<", n, "> ", pathTag.pp,
          "\n   hike",
          "\n    ", hike.pp(db),
          "\n   sTab (prev)",
          "\n    ", sTabState,
          "\n   sTab",
          "\n    ", db.sTab.pp(db),
          "\n   lTab",
          "\n    ", db.lTab.pp,
          "\n"

      check hike.error == AristoError(0)
      check ekih.error == AristoError(0)

      if ekih.legs.len == 0:
        check 0 < ekih.legs.len
      elif ekih.legs[^1].wp.vtx.vType != Leaf:
        check ekih.legs[^1].wp.vtx.vType == Leaf
      else:
        check ekih.legs[^1].wp.vtx.lData.blob == w.accBlob

      if db.lTab.len != n + 1:
        check db.lTab.len == n + 1 # quick leaf access table
        break                      # makes no sense to go on further

      #if 10 < n:
      #  break

    noisy.say "***", "sample ", u, "/", lst.len ," leafs merged: ", count+1
    #break

# ------------------------------------------------------------------------------
# End
# ------------------------------------------------------------------------------
