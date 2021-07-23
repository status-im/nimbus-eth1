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
  enableCliqueAsyncLock* = ##\
    ## Async locks are currently unused by `Clique` but were part of the Go
    ## reference implementation. The unused code fragment from the reference
    ## implementation are buried in the file `clique_unused.nim` and not used
    ## otherwise.
    defined(clique_async_lock)

when enableCliqueAsyncLock:
  include chronos

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

    when enableCliqueAsyncLock:
      asyncLock: AsyncLock ##\
        ## Protects the signer fields

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
