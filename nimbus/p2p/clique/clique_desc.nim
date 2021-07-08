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
## Descriptor Objects for Clique PoA Consensus Protocol
## ====================================================
##
## For details see
## `EIP-225 <https://github.com/ethereum/EIPs/blob/master/EIPS/eip-225.md>`_
## and
## `go-ethereum <https://github.com/ethereum/EIPs/blob/master/EIPS/eip-225.md>`_
##

import
  std/[tables],
  ../../db/db_chain,
  ../../constants,
  ./clique_cfg,
  ./clique_defs,
  ./snapshot/lru_snaps,
  chronos,
  eth/[common, keys, rlp]

type
  # clique/clique.go(142): type SignerFn func(signer [..]
  CliqueSignerFn* =        ## Hashes and signs the data to be signed by
                           ## a backing account
    proc(signer: EthAddress;
         message: openArray[byte]): Result[Hash256,cstring] {.gcsafe.}

  Proposals = Table[EthAddress,bool]

  # clique/clique.go(172): type Clique struct { [..]
  Clique* = ref object ## Clique is the proof-of-authority consensus engine
                       ## proposed to support the Ethereum testnet following
                       ## the Ropsten attacks.
    signer*: EthAddress ##\
      ## Ethereum address of the current signing key

    signFn*: CliqueSignerFn ## Signer function to authorize hashes with
    stopSealReq*: bool      ## Stop running `seal()` function
    stopVHeaderReq*: bool   ## Stop running `verifyHeader()` function
    # signatures => see CliqueCfg

    cfg: CliqueCfg ##\
      ## Common engine parameters to fine tune behaviour

    recents: LruSnaps ##\
      ## Snapshots cache for recent block search

    lastSnap: SnapshotResult ##\
      ## Stashing last snapshot operation here

    proposals: Proposals ##\
      ## Cu1rrent list of proposals we are pushing

    asyncLock: AsyncLock ##\
      ## Protects the signer fields

    fakeDiff: bool ##\
      ## Testing/debugging only: skip difficulty verifications
    debug: bool ##\
      ## Testing/debugging only: debug mode

{.push raises: [Defect].}

# ------------------------------------------------------------------------------
# Public constructor
# ------------------------------------------------------------------------------

# clique/clique.go(191): func New(config [..]
proc newClique*(cfg: CliqueCfg): Clique =
  ## Initialiser for Clique proof-of-authority consensus engine with the
  ## initial signers set to the ones provided by the user.
  Clique(cfg:       cfg,
         recents:   initLruSnaps(cfg),
         proposals: initTable[EthAddress,bool](),
         asyncLock: newAsyncLock())

# ------------------------------------------------------------------------------
# Public debug/pretty print
# ------------------------------------------------------------------------------

proc getPrettyPrinters*(c: Clique): var PrettyPrinters =
  ## Mixin for pretty printers, see `clique/clique_cfg.pp()`
  c.cfg.prettyPrint

proc pp*(rc: var SnapshotResult; indent = 0): string =
  if rc.isOk:
    rc.value.pp(indent)
  else:
    "(error: " & rc.error.pp & ")"

# ------------------------------------------------------------------------------
# Public getters
# ------------------------------------------------------------------------------

proc recents*(c: Clique): var LruSnaps {.inline.} =
  ## Getter
  c.recents

proc proposals*(c: Clique): var Proposals {.inline.} =
  ## Getter
  c.proposals

proc lastSnap*(c: Clique): var SnapshotResult {.inline.} =
  ## Getter, last error message
  c.lastSnap

proc cfg*(c: Clique): auto {.inline.} =
  ## Getter
  c.cfg

proc db*(c: Clique): auto {.inline.} =
  ## Getter
  c.cfg.db

proc debug*(c: Clique): auto {.inline.} =
  ## Getter
  c.debug

proc fakeDiff*(c: Clique): auto {.inline.} =
  ## Getter
  c.fakeDiff

# ------------------------------------------------------------------------------
# Public setters
# ------------------------------------------------------------------------------

proc `db=`*(c: Clique; db: BaseChainDB) {.inline.} =
  ## Setter, re-set database
  c.cfg.db = db
  c.proposals = initTable[EthAddress,bool]()
  c.recents = c.cfg.initLruSnaps
  c.recents.debug = c.debug
  # note that the signatures[] cache need not be flushed

proc `debug=`*(c: Clique; debug: bool) =
  ## Seter, debugging mode on/off and set the `fakeDiff` flag `true`
  c.fakeDiff = true
  c.debug = debug
  c.recents.debug = debug

proc `lastSnap=`*(c: Clique; snap: SnapshotResult) =
  ## Setter, last error message
  c.lastSnap = snap

# ------------------------------------------------------------------------------
# Public lock/unlock
# ------------------------------------------------------------------------------

proc lock*(c: Clique) {.inline, raises: [Defect,CatchableError].} =
  ## Lock descriptor
  waitFor c.asyncLock.acquire

proc unLock*(c: Clique) {.inline, raises: [Defect,AsyncLockError].} =
  ## Unlock descriptor
  c.asyncLock.release

template doExclusively*(c: Clique; action: untyped) =
  ## Handy helper
  c.lock
  action
  c.unlock

# ------------------------------------------------------------------------------
# End
# ------------------------------------------------------------------------------
