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
  std/tables,
  ./clique_cfg,
  ./clique_defs,
  ./snapshot/snapshot_desc,
  chronicles,
  eth/keys,
  stew/[keyed_queue, results]

type
  RawSignature* = array[RawSignatureSize, byte]

  # clique/clique.go(142): type SignerFn func(signer [..]
  CliqueSignerFn* =    ## Hashes and signs the data to be signed by
                       ## a backing account
    proc(signer: EthAddress;
         message: openArray[byte]): Result[RawSignature, cstring] {.gcsafe.}

  Proposals = Table[EthAddress,bool]

  CliqueSnapKey* = ##\
    ## Internal key used for the LRU cache (derived from Hash256).
    array[32,byte]

  CliqueSnapLru = ##\
    ## Snapshots cache
    KeyedQueue[CliqueSnapKey,Snapshot]

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

    cfg: CliqueCfg ##\
      ## Common engine parameters to fine tune behaviour

    recents: CliqueSnapLru ##\
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
      ## walk back to the1 `epoch` header with at least `cfg.roThreshold` blocks
      ## apart from the current header. This is how it is done in the reference
      ## implementation.
      ##
      ## Leving the flag `false`, the assumption is that all the checkponts
      ## before have been vetted already regardless of the current branch. So
      ## the nearest `epoch` header is used.

{.push raises: [].}

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
                  snapshot:  cfg.newSnapshot(BlockHeader()),
                  proposals: initTable[EthAddress,bool]())

# ------------------------------------------------------------------------------
# Public debug/pretty print
# ------------------------------------------------------------------------------

proc `$`*(e: CliqueError): string =
  ## Join text fragments
  result = $e[0]
  if e[1] != "":
    result &= ": " & e[1]

# ------------------------------------------------------------------------------
# Public getters
# ------------------------------------------------------------------------------

proc recents*(
    c: Clique;
      ): var KeyedQueue[CliqueSnapKey,Snapshot]
      =
  ## Getter
  c.recents

proc proposals*(c: Clique): var Proposals =
  ## Getter
  c.proposals

proc snapshot*(c: Clique): Snapshot =
  ## Getter, last successfully processed snapshot.
  c.snapshot

proc failed*(c: Clique): CliqueFailed =
  ## Getter, last snapshot error.
  c.failed

proc cfg*(c: Clique): CliqueCfg =
  ## Getter
  c.cfg

proc db*(c: Clique): ChainDBRef =
  ## Getter
  c.cfg.db

proc applySnapsMinBacklog*(c: Clique): bool =
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

proc `db=`*(c: Clique; db: ChainDBRef) =
  ## Setter, re-set database
  c.cfg.db = db
  c.proposals = initTable[EthAddress,bool]()

proc `snapshot=`*(c: Clique; snaps: Snapshot) =
  ## Setter
  c.snapshot = snaps

proc `failed=`*(c: Clique; failure: CliqueFailed) =
  ## Setter
  c.failed = failure

proc `applySnapsMinBacklog=`*(c: Clique; value: bool) =
  ## Setter
  c.applySnapsMinBacklog = value

# ------------------------------------------------------------------------------
# End
# ------------------------------------------------------------------------------
