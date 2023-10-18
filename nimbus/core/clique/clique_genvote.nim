# Nimbus
# Copyright (c) 2018 Status Research & Development GmbH
# Licensed under either of
#  * Apache License, version 2.0, ([LICENSE-APACHE](LICENSE-APACHE) or
#    http://www.apache.org/licenses/LICENSE-2.0)
#  * MIT license ([LICENSE-MIT](LICENSE-MIT) or
#    http://opensource.org/licenses/MIT)
# at your option. This file may not be copied, modified, or distributed except
# according to those terms.

##
## Generate PoA Voting Header
## ==========================
##
## For details see
## `EIP-225 <https://github.com/ethereum/EIPs/blob/master/EIPS/eip-225.md>`_
## and
## `go-ethereum <https://github.com/ethereum/EIPs/blob/master/EIPS/eip-225.md>`_
##

import
  std/[sequtils],
  eth/[common, keys],
  ../../constants,
  ./clique_cfg,
  ./clique_defs,
  ./clique_desc,
  ./clique_helpers

{.push raises: [].}

# ------------------------------------------------------------------------------
# Private functions
# ------------------------------------------------------------------------------

# clique/snapshot_test.go(49): func (ap *testerAccountPool) [..]
proc extraCheckPoint(header: var BlockHeader; signers: openArray[EthAddress]) =
  ## creates a Clique checkpoint signer section from the provided list
  ## of authorized signers and embeds it into the provided header.
  header.extraData.setLen(EXTRA_VANITY)
  header.extraData.add signers.mapIt(toSeq(it)).concat
  header.extraData.add 0.byte.repeat(EXTRA_SEAL)

# clique/snapshot_test.go(77): func (ap *testerAccountPool) sign(header n[..]
proc sign(header: var BlockHeader; signer: PrivateKey) =
  ## sign calculates a Clique digital signature for the given block and embeds
  ## it back into the header.
  #
  # Sign the header and embed the signature in extra data
  let
    hashData = header.hashSealHeader.data
    signature = signer.sign(SkMessage(hashData)).toRaw
    extraLen = header.extraData.len
  header.extraData.setLen(extraLen -  EXTRA_SEAL)
  header.extraData.add signature

# ------------------------------------------------------------------------------
# Public functions
# ------------------------------------------------------------------------------

# clique/snapshot_test.go(415): blocks, _ := core.GenerateChain(&config, [..]
proc cliqueGenvote*(
    c: Clique;
    voter: EthAddress;             # new voter account/identity
    seal: PrivateKey;              # signature key
    parent: BlockHeader;
    elapsed = EthTime(0);
    voteInOk = false;              # vote in the new voter if `true`
    outOfTurn = false;
    checkPoint: seq[EthAddress] = @[]): BlockHeader =
  ## Generate PoA voting header (as opposed to `epoch` synchronisation header.)
  ## The function arguments are as follows:
  ##
  ## :c:
  ##   Clique descriptor. see the `newClique()` object constructor.
  ##
  ## :voter:
  ##    New voter account address to vote in or out (see `voteInOk`). A trivial
  ##    example for the first block #1 header would be choosing one of the
  ##    accounts listed in the `extraData` field fo the genesis header (note
  ##    that Goerli has exactly one of those accounts.) This trivial example
  ##    has no effect on the authorised voters' list.
  ##
  ## :seal:
  ##    Private key related to an authorised voter account. Again, a trivial
  ##    example for the block #1 header would be to (know and) use the
  ##    associated key for one of the accounts listed in the `extraData` field
  ##    fo the genesis header.
  ##
  ## :parent:
  ##    parent header to chain with (not necessarily on block chain yet). For
  ##    a block #1 header as a trivial example, this would be the genesis
  ##    header.
  ##
  ## :elapsed:
  ##    Optional timestamp distance from parent. This value defaults to valid
  ##    minimum time interval `c.cfg.period`
  ##
  ## :voteInOk:
  ##    Role of voting account. If `true`, the `voter` account address is voted
  ##    in to be accepted as authorised account. If `false`, the `voter` account
  ##    is voted to be removed (if it exists as authorised account, at all.)
  ##
  ## :outOfTurn:
  ##    Must be `false` if the `voter` is `in-turn` which is defined as the
  ##    property of a header block number retrieving the `seal` account address
  ##    when used as list index (modulo list-length) into the (internally
  ##    calculated and sorted) list of authorised signers. Absence of this
  ##    property is called `out-of-turn`.
  ##
  ##    The classification `in-turn` and `out-of-turn` is used only with a
  ##    multi mining strategy where an `in-turn` block is slightly preferred.
  ##    Nevertheless, this property is to be locked into the block chain. In a
  ##    trivial example of an authorised signers list with exactly one entry,
  ##    all block numbers are zero modulo one, so are `in-turn`, and
  ##    `outOfTurn` would be left `false`.
  ##
  ## :checkPoint:
  ##    List of currently authorised signers. According to the Clique protocol
  ##    EIP-225, this list must be the same as the internally computed list of
  ##    authorised signers from the block chain.
  ##
  ##    This list must appear on an `epoch` block and nowhere else. An `epoch`
  ##    block is a block where the block number is a multiple of `c.cfg.epoch`.
  ##    Typically, `c.cfg.epoch` is initialised as `30'000`.
  ##
  let timeElapsed = if elapsed == EthTime(0): c.cfg.period  else: elapsed

  result = BlockHeader(
    parentHash:  parent.blockHash,
    ommersHash:  EMPTY_UNCLE_HASH,
    stateRoot:   parent.stateRoot,
    timestamp:   parent.timestamp + timeElapsed,
    txRoot:      EMPTY_ROOT_HASH,
    receiptRoot: EMPTY_ROOT_HASH,
    blockNumber: parent.blockNumber + 1,
    gasLimit:    parent.gasLimit,
    #
    # clique/snapshot_test.go(417): gen.SetCoinbase(accounts.address( [..]
    coinbase:    voter,
    #
    # clique/snapshot_test.go(418): if tt.votes[j].auth {
    nonce:       if voteInOk: NONCE_AUTH else: NONCE_DROP,
    #
    # clique/snapshot_test.go(436): header.Difficulty = diffInTurn [..]
    difficulty:  if outOfTurn: DIFF_NOTURN else: DIFF_INTURN,
    #
    extraData:   0.byte.repeat(EXTRA_VANITY + EXTRA_SEAL))

  # clique/snapshot_test.go(432): if auths := tt.votes[j].checkpoint; [..]
  if 0 < checkPoint.len:
    result.extraCheckPoint(checkPoint)

  # Generate the signature and embed it into the header
  result.sign(seal)


proc cliqueGenvote*(
    c: Clique; voter: EthAddress; seal: PrivateKey;
    elapsed = EthTime(0);
    voteInOk = false;
    outOfTurn = false;
    checkPoint: seq[EthAddress] = @[]): BlockHeader
    {.gcsafe, raises: [CatchableError].} =
  ## Variant of `clique_genvote()` where the `parent` is the canonical head
  ## on the the block chain database.
  ##
  ## Trivial example (aka smoke test):
  ##
  ##    :signature:       `S`
  ##    :account address: `a(S)`
  ##    :genesis:          extraData contains exactly one signer `a(S)`
  ##
  ##    [..]
  ##
  ##    | import pkg/[times], ..
  ##    | import p2p/[chain,clique], p2p/clique/clique_genvote, ..
  ##
  ##    [..]
  ##
  ##    | var db: CoreDbRef = ...
  ##    | var c = db.newChain
  ##
  ##
  ##    | \# overwrite, typically initialised at 15s
  ##    | const threeSecs = initDuration(seconds = 3)
  ##    | c.clique.cfg.period = threeSecs
  ##
  ##
  ##    | \# create first block (assuming empty block chain), mind `a(S)`, `S`
  ##    | let header = c.clique.clique_genvote(`a(S)`, `S`, elapsed = threeSecs)
  ##
  ##    [..]
  ##
  ##    let ok = c.persistBlocks(@[header],@[BlockBody()])
  ##
  ##    [..]
  ##
  c.clique_genvote(voter, seal,
                   parent = c.cfg.db.getCanonicalHead,
                   elapsed = elapsed,
                   voteInOk = voteInOk,
                   outOfTurn = outOfTurn,
                   checkPoint = checkPoint)

# ------------------------------------------------------------------------------
# End
# ------------------------------------------------------------------------------
