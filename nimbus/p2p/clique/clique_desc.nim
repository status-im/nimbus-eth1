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
  ../../constants,
  ./clique_cfg,
  ./clique_defs,
  ./recent_snaps,
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
  Clique* = object ## Clique is the proof-of-authority consensus engine
                   ## proposed to support the Ethereum testnet following
                   ## the Ropsten attacks.
    cCfg: CliqueCfg        ## Consensus engine parameters to fine tune behaviour

    cRecents: RecentSnaps   ## Snapshots for recent block to speed up reorgs
    # signatures => see CliqueCfg

    cProposals: Proposals   ## Cu1rrent list of proposals we are pushing

    signer*: EthAddress     ## Ethereum address of the signing key
    signFn*: CliqueSignerFn ## Signer function to authorize hashes with
    cLock: AsyncLock        ## Protects the signer fields

    stopSealReq*: bool      ## Stop running `seal()` function
    stopVHeaderReq*: bool   ## Stop running `verifyHeader()` function

    cFakeDiff: bool         ## Testing only: skip difficulty verifications
    cDebug: bool            ## debug mode

{.push raises: [Defect].}

# ------------------------------------------------------------------------------
# Public constructor
# ------------------------------------------------------------------------------

# clique/clique.go(191): func New(config [..]
proc initClique*(c: var Clique; cfg: CliqueCfg) =
  ## Initialiser for Clique proof-of-authority consensus engine with the
  ## initial signers set to the ones provided by the user.
  c.cCfg = cfg
  c.cRecents = initRecentSnaps(cfg)
  c.cProposals = initTable[EthAddress,bool]()
  c.cLock = newAsyncLock()

proc initClique*(cfg: CliqueCfg): Clique =
  result.initClique(cfg)

# ------------------------------------------------------------------------------
# Public debug/pretty print
# ------------------------------------------------------------------------------

proc setDebug*(c: var Clique; debug: bool) =
  ## Set debugging mode on/off and set the `fakeDiff` flag `true`
  c.cFakeDiff = true
  c.cDebug = debug
  c.cRecents.setDebug(debug)

proc pp*(rc: var Result[Snapshot,CliqueError]; indent = 0): string =
  if rc.isOk:
    rc.value.pp(indent)
  else:
    "(error: " & rc.error.pp & ")"

# ------------------------------------------------------------------------------
# Public getters
# ------------------------------------------------------------------------------

proc cfg*(c: var Clique): auto {.inline.} =
  ## Getter
  c.cCfg

proc recents*(c: var Clique): var RecentSnaps {.inline.} =
  ## Getter
  c.cRecents

proc proposals*(c: var Clique): var Proposals {.inline.} =
  ## Getter
  c.cProposals

proc debug*(c: var Clique): auto {.inline.} =
  ## Getter
  c.cDebug

proc fakeDiff*(c: var Clique): auto {.inline.} =
  ## Getter
  c.cFakeDiff

# ------------------------------------------------------------------------------
# Public lock/unlock
# ------------------------------------------------------------------------------

proc lock*(c: var Clique) {.inline, raises: [Defect,CatchableError].} =
  ## Lock descriptor
  waitFor c.cLock.acquire

proc unLock*(c: var Clique) {.inline, raises: [Defect,AsyncLockError].} =
  ## Unlock descriptor
  c.cLock.release

template doExclusively*(c: var Clique; action: untyped) =
  ## Handy helper
  c.lock
  action
  c.unlock

# ------------------------------------------------------------------------------
# End
# ------------------------------------------------------------------------------
