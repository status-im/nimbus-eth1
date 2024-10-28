# nimbus-eth1
# Copyright (c) 2023-2024 Status Research & Development GmbH
# Licensed under either of
#  * Apache License, version 2.0, ([LICENSE-APACHE](LICENSE-APACHE) or
#    http://www.apache.org/licenses/LICENSE-2.0)
#  * MIT license ([LICENSE-MIT](LICENSE-MIT) or
#    http://opensource.org/licenses/MIT)
# at your option. This file may not be copied, modified, or distributed
# except according to those terms.

{.push raises: [].}

import
  system/ansi_c,
  std/[strformat, math, hashes],
  stew/staticfor,
  chronicles,
  eth/common,
  results,
  "."/[aristo_desc, aristo_get, aristo_serialise, aristo_walk/persistent],
  ./aristo_desc/desc_backend

type BasicBloomFilter = object
  # School book implementation of bloom filter based on
  # https://github.com/save-buffer/bloomfilter_benchmarks.
  #
  # In theory, this bloom filter could be turned into a reusable component but
  # it is fairly specialised to the particular use case and gets used in a
  # tight/hot loop in the code - a generalisation would require care so as not
  # to introduce overhead but could of course be further optimised using
  bytes: ptr UncheckedArray[byte]

proc computeBits(n: int, epsilon: float): int =
  # Number of bits in the bloom filter required for n elements and eposilon
  # false positive rate
  int(-1.4427 * float(n) * log2(epsilon) + 0.5)

proc computeHashFns(epsilon: float): int =
  # Number of hash functions given the desired false positive rate
  int(-log2(epsilon) + 0.5)

const
  bloomRate = 0.002
    # The leaf cache computation is fairly sensitive to false positives as these
    # ripple up the branch trie with false postivies being amplified by trie
    # branching - this has to be balanced with the cost which
    # goes up fairly quickly with ~13 bits per key at 0.002, meaning ~2gb of
    # memory for the current setting below!
  bloomHashes = computeHashFns(bloomRate)
  expectedKeys = 1500000000
    # expected number of elements in the bloom filter - this is reported as
    # `keys` below and will need adjusting - the value is more or less accurate
    # on mainnet as of block 2100000 (~oct 2024) for the number of leaves
    # present - we use leaf count because bloom filter accuracy is most
    # important for the first round of branches.
    # TODO rocksdb can estimate the number of keys present in the vertex table -
    #      this would provide a reasonable estimate of what the bloom table size
    #      should be, though in reality we want leaf count per above argument -
    #      at the time of writing leaves make up around 3/4 of all verticies
  bloomSize = uint32((computeBits(expectedKeys, bloomRate) + 7) / 8)

func hashes(v: uint64): (uint32, uint32) =
  # Use the two halves of an uint64 to create two independent hashes functions
  # for the bloom that allow efficiently generating more bloom hash functions
  # per Kirsch and Mitzenmacher:
  # https://www.eecs.harvard.edu/~michaelm/postscripts/tr-02-05.pdf
  let
    v = uint64(hash(v)) # `hash` for a better spread of bits into upper half
    h1 = uint32(v)
    h2 = uint32(v shr 32)
  (h1, h2)

func insert(filter: var BasicBloomFilter, v: uint64) =
  let (h1, h2) = hashes(v)

  staticFor i, 0 ..< bloomHashes:
    let
      hash = (h1 + i * h2)
      bitIdx = uint8(hash mod 8)
      byteIdx = (hash div 8) mod bloomSize
    filter.bytes[byteIdx] = filter.bytes[byteIdx] or (1'u8 shl bitIdx)

func query(filter: BasicBloomFilter, v: uint64): bool =
  let (h1, h2) = hashes(v)

  var match = 1'u8

  staticFor i, 0 ..< bloomHashes:
    let
      hash = (h1 + i * h2)
      bitIdx = uint8(hash mod 8)
      byteIdx = (hash div 8) mod bloomSize
    match = match and ((filter.bytes[byteIdx] shr bitIdx) and 1)

  match > 0

proc init(T: type BasicBloomFilter): T =
  # We use the C memory allocator so as to return memory to the operating system
  # at the end of the computation - we don't want the one-off blob to remain in
  # the hands of the Nim GC.
  # `calloc` to get zeroed memory out of the box
  let memory = c_calloc(csize_t(bloomSize), 1)
  doAssert memory != nil, "Could not allocate memory for bloom filter"
  T(bytes: cast[ptr UncheckedArray[byte]](memory))

proc release(v: BasicBloomFilter) =
  # TODO with orc, this could be a destructor
  c_free(v.bytes)

type WriteBatch = tuple[writer: PutHdlRef, count: int, depth: int, prefix: uint64]

# Keep write batch size _around_ 1mb, give or take some overhead - this is a
# tradeoff between efficiency and memory usage with diminishing returns the
# larger it is..
const batchSize = 1024 * 1024 div (sizeof(RootedVertexID) + sizeof(HashKey))

proc flush(batch: var WriteBatch, db: AristoDbRef): Result[void, AristoError] =
  if batch.writer != nil:
    ?db.backend.putEndFn batch.writer
    batch.writer = nil
  ok()

proc putKey(
    batch: var WriteBatch, db: AristoDbRef, rvid: RootedVertexID, key: HashKey
): Result[void, AristoError] =
  if batch.writer == nil:
    doAssert db.backend != nil, "source data is from the backend"
    batch.writer = ?db.backend.putBegFn()

  db.backend.putKeyFn(batch.writer, rvid, key)
  batch.count += 1

  ok()

func progress(batch: WriteBatch): string =
  # Return an approximation on how much of the keyspace has been covered by
  # looking at the path prefix that we're currently processing
  &"{(float(batch.prefix) / float(uint64.high)) * 100:02.2f}%"

func enter(batch: var WriteBatch, nibble: int) =
  batch.depth += 1
  if batch.depth <= 16:
    batch.prefix += uint64(nibble) shl ((16 - batch.depth) * 4)

func leave(batch: var WriteBatch, nibble: int) =
  if batch.depth <= 16:
    batch.prefix -= uint64(nibble) shl ((16 - batch.depth) * 4)
  batch.depth -= 1

proc putKeyAtLevel(
    db: AristoDbRef,
    rvid: RootedVertexID,
    key: HashKey,
    level: int,
    batch: var WriteBatch,
): Result[void, AristoError] =
  ## Store a hash key in the given layer or directly to the underlying database
  ## which helps ensure that memory usage is proportional to the pending change
  ## set (vertex data may have been committed to disk without computing the
  ## corresponding hash!)

  # Only put computed keys in the database which keeps churn down by focusing on
  # the ones that do not change!
  if level == -2:
    ?batch.putKey(db, rvid, key)

    if batch.count mod batchSize == 0:
      ?batch.flush(db)

      if batch.count mod (batchSize * 100) == 0:
        info "Writing computeKey cache", keys = batch.count, accounts = batch.progress
      else:
        debug "Writing computeKey cache", keys = batch.count, accounts = batch.progress
  else:
    db.deltaAtLevel(level).kMap[rvid] = key

  ok()

func maxLevel(cur, other: int): int =
  # Compare two levels and return the topmost in the stack, taking into account
  # the odd reversal of order around the zero point
  if cur < 0:
    max(cur, other) # >= 0 is always more topmost than <0
  elif other < 0:
    cur
  else:
    min(cur, other) # Here the order is reversed and 0 is the top layer

template encodeLeaf(w: var RlpWriter, pfx: NibblesBuf, leafData: untyped): HashKey =
  w.startList(2)
  w.append(pfx.toHexPrefix(isLeaf = true).data())
  w.append(leafData)
  w.finish().digestTo(HashKey)

template encodeBranch(w: var RlpWriter, subKeyForN: untyped): HashKey =
  w.startList(17)
  for n {.inject.} in 0 .. 15:
    w.append(subKeyForN)
  w.append EmptyBlob
  w.finish().digestTo(HashKey)

template encodeExt(w: var RlpWriter, pfx: NibblesBuf, branchKey: HashKey): HashKey =
  w.startList(2)
  w.append(pfx.toHexPrefix(isLeaf = false).data())
  w.append(branchKey)
  w.finish().digestTo(HashKey)

proc computeKeyImpl(
    db: AristoDbRef,
    rvid: RootedVertexID,
    batch: var WriteBatch,
    bloom: ptr BasicBloomFilter = nil,
): Result[(HashKey, int), AristoError] =
  # The bloom filter available used only when creating the key cache from an
  # empty state
  if bloom == nil or bloom[].query(uint64(rvid.vid)):
    db.getKeyRc(rvid).isErrOr:
      # Value cached either in layers or database
      return ok value

  let (vtx, vl) = ?db.getVtxRc(rvid, {GetVtxFlag.PeekCache})

  # Top-most level of all the verticies this hash compution depends on
  var level = vl

  # TODO this is the same code as when serializing NodeRef, without the NodeRef
  var writer = initRlpWriter()

  let key =
    case vtx.vType
    of Leaf:
      writer.encodeLeaf(vtx.pfx):
        case vtx.lData.pType
        of AccountData:
          let
            stoID = vtx.lData.stoID
            skey =
              if stoID.isValid:
                let (skey, sl) =
                  ?db.computeKeyImpl((stoID.vid, stoID.vid), batch, bloom)
                level = maxLevel(level, sl)
                skey
              else:
                VOID_HASH_KEY

          rlp.encode Account(
            nonce: vtx.lData.account.nonce,
            balance: vtx.lData.account.balance,
            storageRoot: skey.to(Hash32),
            codeHash: vtx.lData.account.codeHash,
          )
        of RawData:
          vtx.lData.rawBlob
        of StoData:
          # TODO avoid memory allocation when encoding storage data
          rlp.encode(vtx.lData.stoData)
    of Branch:
      template writeBranch(w: var RlpWriter): HashKey =
        w.encodeBranch:
          let vid = vtx.bVid[n]
          if vid.isValid:
            batch.enter(n)
            let (bkey, bl) = ?db.computeKeyImpl((rvid.root, vid), batch, bloom)
            batch.leave(n)

            level = maxLevel(level, bl)
            bkey
          else:
            VOID_HASH_KEY

      if vtx.pfx.len > 0: # Extension node
        writer.encodeExt(vtx.pfx):
          var bwriter = initRlpWriter()
          bwriter.writeBranch()
      else:
        writer.writeBranch()

  # Cache the hash into the same storage layer as the the top-most value that it
  # depends on (recursively) - this could be an ephemeral in-memory layer or the
  # underlying database backend - typically, values closer to the root are more
  # likely to live in an in-memory layer since any leaf change will lead to the
  # root key also changing while leaves that have never been hashed will see
  # their hash being saved directly to the backend.
  ?db.putKeyAtLevel(rvid, key, level, batch)

  ok (key, level)

proc computeKeyImpl(
    db: AristoDbRef, rvid: RootedVertexID, bloom: ptr BasicBloomFilter
): Result[HashKey, AristoError] =
  var batch: WriteBatch
  let res = computeKeyImpl(db, rvid, batch, bloom)
  if res.isOk:
    ?batch.flush(db)

    if batch.count > 0:
      if batch.count >= batchSize * 100:
        info "Wrote computeKey cache", keys = batch.count, accounts = "100.00%"
      else:
        debug "Wrote computeKey cache", keys = batch.count, accounts = "100.00%"

  ok (?res)[0]

proc computeKey*(
    db: AristoDbRef, # Database, top layer
    rvid: RootedVertexID, # Vertex to convert
): Result[HashKey, AristoError] =
  ## Compute the key for an arbitrary vertex ID. If successful, the length of
  ## the resulting key might be smaller than 32. If it is used as a root vertex
  ## state/hash, it must be converted to a `Hash32` (using (`.to(Hash32)`) as
  ## in `db.computeKey(rvid).value.to(Hash32)` which always results in a
  ## 32 byte value.

  computeKeyImpl(db, rvid, nil)

proc computeLeafKeysImpl(
    T: type, db: AristoDbRef, root: VertexID
): Result[void, AristoError] =
  for x in T.walkKeyBe(db):
    debug "Skipping leaf key computation, cache is not empty"
    return ok()

  # Key computation function that works by iterating over the entries in the
  # database (instead of traversing trie using point lookups) - due to how
  # rocksdb is organised, this cache-friendly traversal order turns out to be
  # more efficient even if we "touch" a lot of irrelevant entries.
  # Computation works bottom-up starting with the leaves and proceeding with
  # branches whose children were computed in the previous round one "layer"
  # at a time until the the number of successfully computed nodes grows low.
  # TODO progress indicator
  info "Writing key cache (this may take a while)"

  var batch: WriteBatch

  # Bloom filter keeping track of keys we're added to the database already so
  # as to avoid expensive speculative lookups
  var bloom = BasicBloomFilter.init()
  defer:
    bloom.release()

  var
    # Reuse rlp writers to avoid superfluous memory allocations
    writer = initRlpWriter()
    writer2 = initRlpWriter()
    level = 0

  # Start with leaves - at the time of writing, this is roughly 3/4 of the
  # of the entries in the database on mainnet - the ratio roughly corresponds to
  # the fill ratio of the deepest branch nodes as nodes close to the MPT root
  # don't come in significant numbers

  for (rvid, vtx) in T.walkVtxBe(db, {Leaf}):
    if vtx.lData.pType == AccountData and vtx.lData.stoID.isValid:
      # Accounts whose key depends on the storage trie typically will not yet
      # have their root node computed and several such contracts are
      # significant in size, meaning that we might as well let their leaves
      # be computed and then top up during regular trie traversal.
      continue

    writer.clear()

    let key = writer.encodeLeaf(vtx.pfx):
      case vtx.lData.pType
      of AccountData:
        writer2.clear()
        writer2.append Account(
          nonce: vtx.lData.account.nonce,
          balance: vtx.lData.account.balance,
          # Accounts with storage filtered out above
          storageRoot: EMPTY_ROOT_HASH,
          codeHash: vtx.lData.account.codeHash,
        )
        writer2.finish()
      of RawData:
        vtx.lData.rawBlob
      of StoData:
        writer2.clear()
        writer2.append(vtx.lData.stoData)
        writer2.finish()

    ?batch.putKey(db, rvid, key)

    if batch.count mod batchSize == 0:
      ?batch.flush(db)

      if batch.count mod (batchSize * 100) == 0:
        info "Writing leaves", keys = batch.count, level
      else:
        debug "Writing leaves", keys = batch.count, level

    bloom.insert(uint64(rvid.vid))

  let leaves = batch.count

  # The leaves have been written - we'll now proceed to branches expecting
  # diminishing returns for each layer - not only beacuse there are fewer nodes
  # closer to the root in the trie but also because leaves we skipped over lead
  # larger and larger branch gaps and the advantage of iterating in disk order
  # is lost
  var lastRound = leaves

  level += 1

  # 16*16 looks like "2 levels of MPT" but in reality, the branch nodes close
  # to the leaves are sparse - on average about 4 nodes per branch on mainnet -
  # meaning that we'll do 3-4 levels of branch depending on the network
  while lastRound > (leaves div (16 * 16)):
    info "Starting branch layer", keys = batch.count, lastRound, level
    var round = 0
    for (rvid, vtx) in T.walkVtxBe(db, {Branch}):
      if vtx.pfx.len > 0:
        # TODO there shouldn't be many of these - is it worth the lookup?
        continue

      if level > 1:
        # A hit on the bloom filter here means we **maybe** already computed a
        # key for this branch node - we could verify this with a lookup but
        # the generally low false positive rate makes this check more expensive
        # than simply revisiting the node using trie traversal.
        if bloom.query(uint64(rvid.vid)):
          continue

      block branchKey:
        for b in vtx.bVid:
          if b.isValid and not bloom.query(uint64(b)):
            # If any child is missing from the branch, we can't compute the key
            # trivially
            break branchKey

        writer.clear()
        let key = writer.encodeBranch:
          let vid = vtx.bVid[n]
          if vid.isValid:
            let bkey = db.getKeyUbe((rvid.root, vid)).valueOr:
              # False positive on the bloom filter lookup
              break branchKey
            bkey
          else:
            VOID_HASH_KEY

        ?batch.putKey(db, rvid, key)

        if batch.count mod batchSize == 0:
          ?batch.flush(db)
          if batch.count mod (batchSize * 100) == 0:
            info "Writing branches", keys = batch.count, round, level
          else:
            debug "Writing branches", keys = batch.count, round, level

        round += 1
        bloom.insert(uint64(rvid.vid))

    lastRound = round
    level += 1

  ?batch.flush(db)

  info "Key cache base written",
    keys = batch.count, lastRound, leaves, branches = batch.count - leaves

  let rc = computeKeyImpl(db, (root, root), addr bloom)
  if rc.isOk() or rc.error() == GetVtxNotFound:
    # When there's no root vertex, the database is likely empty
    ok()
  else:
    err(rc.error())

proc computeKeys*(db: AristoDbRef, root: VertexID): Result[void, AristoError] =
  ## Computing the leaf keys is a pre-processing step for when hash cache is
  ## empty.
  ##
  ## Computing it by traversing the trie can take days because of the mismatch
  ## between trie traversal order and the on-disk VertexID-based sorting.
  ##
  ## This implementation speeds up the inital seeding of the cache by traversing
  ## the full state in on-disk order and computing hashes bottom-up instead.
  case db.backend.kind
  of BackendMemory:
    MemBackendRef.computeLeafKeysImpl db, root
  of BackendRocksDB, BackendRdbHosting:
    RdbBackendRef.computeLeafKeysImpl db, root
  of BackendVoid:
    ok()

# ------------------------------------------------------------------------------
# End
# ------------------------------------------------------------------------------
