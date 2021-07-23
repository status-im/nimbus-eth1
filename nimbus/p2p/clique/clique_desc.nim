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
  ./snapshot/[lru_snaps, snapshot_desc],
  chronicles,
  eth/[common, keys, rlp],
  stew/results

const
  traceCliqueMsg* = ##\
    ## Set `true` for enabling messages => `clique_cfg.say()`. Using the
    ## `-d:debug` compiler flag enabled debugging code which must be enabled
    ## with setting `clique_cfg.CliqueCfg.debug` to `true`.
    defined(debug)

  enableCliqueAsyncLock* = ##\
    ## Async locks are currently unused by `Clique` but were part of the Go
    ## reference implementation. The unused code fragment from the reference
    ## implementation are buried in the file `clique_unused.nim` and not used
    ## otherwise.
    defined(clique_async_lock)

when traceCliqueMsg:
  import std/[sequtils, strutils, times]

when enableCliqueAsyncLock:
  import chronos

type
  # clique/clique.go(142): type SignerFn func(signer [..]
  CliqueSignerFn* =    ## Hashes and signs the data to be signed by
                       ## a backing account
    proc(signer: EthAddress;
         message: openArray[byte]): Result[Hash256,cstring] {.gcsafe.}

  Proposals = Table[EthAddress,bool]

  CliqueFailed* = ##\
    ## Last failed state: block hash and error result
    (Hash256, CliqueError)

  # clique/clique.go(172): type Clique struct { [..]
  Clique* = ref object ##\
    ## Clique is the proof-of-authority consensus engine proposed to support
    ## the Ethereum testnet following the Ropsten attacks.

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

    snapshot: Snapshot ##\
      ## Last successful snapshot

    failed: CliqueFailed ##\
      ## Last verification error (if any)

    proposals: Proposals ##\
      ## Cu1rrent list of proposals we are pushing

    applySnapsMinBacklog: bool ##\
      ## Epoch is a restart and sync point. Eip-225 requires that the epoch
      ## header contains the full list of currently authorised signers.
      ##
      ## If this flag is set `true`, then the `cliqueSnapshot()` function will
      ## walk back to the `epoch` header with at least `cfg.roThreshold` blocks
      ## apart from the current header. This is how it is done in the reference
      ## implementation.
      ##
      ## Leving the flag `false`, the assumption is that all the checkponts
      ## before have been vetted already regardless of the current branch. So
      ## the nearest `epoch` header is used.

    when enableCliqueAsyncLock:
      asyncLock: AsyncLock ##\
        ## Protects the signer fields

    # Debugging helpers ...
    when traceCliqueMsg:
      tFlush: bool
      tLog: Time
      tCache: string

{.push raises: [Defect].}

logScope:
  topics = "clique PoA constructor"

# ------------------------------------------------------------------------------
# Public constructor
# ------------------------------------------------------------------------------

# clique/clique.go(191): func New(config [..]
proc newClique*(cfg: CliqueCfg): Clique =
  ## Initialiser for Clique proof-of-authority consensus engine with the
  ## initial signers set to the ones provided by the user.
  result = Clique(cfg:       cfg,
                  recents:   cfg.initLruSnaps,
                  snapshot:  cfg.newSnapshot(BlockHeader()),
                  proposals: initTable[EthAddress,bool]())
  when enableCliqueAsyncLock:
    result.asyncLock = newAsyncLock()

# ------------------------------------------------------------------------------
# Public /pretty print
# ------------------------------------------------------------------------------

# Debugging only
proc getPrettyPrinters*(c: Clique): var PrettyPrinters =
  ## Mixin for pretty printers, see `clique/clique_cfg.pp()`
  c.cfg.prettyPrint

proc `$`*(e: CliqueError): string =
  ## Join text fragments
  result = $e[0]
  if e[1] != "":
    result &= ": " & e[1]

proc sayClique*(c: Clique; v: varargs[string,`$`]) {.inline.} =
  ## Echo replacement referring to `clique_cfg.say()`. Printed texts are
  ## prefixed by the elapsed time (in milli seconds) since the last invocation.
  ## When elapsed time between invocations is smaller than a miilli second,
  ## only the last invocation prints the test.
  discard
  when traceCliqueMsg:
    let
      now = getTime()
    if c.tLog == Time():
      c.tLog = now
    let
      ela = (now - c.tLog).inMilliSeconds
      msg = "(" & $ela & ") " & toSeq(v).join
    c.tLog = now
    if ela == 0 and not c.tFlush:
      c.tCache = msg
    else:
      if c.tCache != "":
        c.cfg.say c.tCache
        c.tCache = ""
      c.cfg.say msg
      c.tFlush = false

proc sayCliqueFlush*(c: Clique) {.inline.} =
  discard
  when traceSnapshotMsg:
    c.tFlush = true

proc sayCliqueClear*(c: Clique) {.inline.} =
  discard
  when traceSnapshotMsg:
    c.tFlush = false
    c.tLog = getTime()
    c.tCache = ""

# ------------------------------------------------------------------------------
# Public getters
# ------------------------------------------------------------------------------

proc recents*(c: Clique): var LruSnaps {.inline.} =
  ## Getter
  c.recents

proc proposals*(c: Clique): var Proposals {.inline.} =
  ## Getter
  c.proposals

proc snapshot*(c: Clique): auto {.inline.} =
  ## Getter, last successfully processed snapshot.
  c.snapshot

proc failed*(c: Clique): auto {.inline.} =
  ## Getter, last snapshot error.
  c.failed

proc cfg*(c: Clique): auto {.inline.} =
  ## Getter
  c.cfg

proc db*(c: Clique): auto {.inline.} =
  ## Getter
  c.cfg.db

proc applySnapsMinBacklog*(c: Clique): auto {.inline.} =
  ## Getter.
  ##
  ## If this flag is set `true`, then the `cliqueSnapshot()` function will
  ## walk back to the `epoch` header with at least `cfg.roThreshold` blocks
  ## apart from the current header. This is how it is done in the reference
  ## implementation.
  ##
  ## Setting the flag `false` which is the default, the assumption is that all
  ## the checkponts before have been vetted already regardless of the current
  ## branch. So the nearest `epoch` header is used.
  c.applySnapsMinBacklog

# ------------------------------------------------------------------------------
# Public setters
# ------------------------------------------------------------------------------

proc `db=`*(c: Clique; db: BaseChainDB) {.inline.} =
  ## Setter, re-set database
  c.cfg.db = db
  c.proposals = initTable[EthAddress,bool]()
  c.recents = c.cfg.initLruSnaps

proc `snapshot=`*(c: Clique; snaps: Snapshot) =
  ## Setter
  c.snapshot = snaps

proc `failed=`*(c: Clique; failure: CliqueFailed) =
  ## Setter
  c.failed = failure

proc applySnapsMinBacklog*(c: Clique; value: bool) {.inline.} =
  ## Setter
  c.applySnapsMinBacklog = value

# ------------------------------------------------------------------------------
# Public lock/unlock
# ------------------------------------------------------------------------------

when enableCliqueAsyncLock:
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
