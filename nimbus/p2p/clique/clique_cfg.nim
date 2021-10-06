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
## Clique PoA Conmmon Config
## =========================
##
## Constants used by Clique proof-of-authority consensus protocol, see
## `EIP-225 <https://github.com/ethereum/EIPs/blob/master/EIPS/eip-225.md>`_
## and
## `go-ethereum <https://github.com/ethereum/EIPs/blob/master/EIPS/eip-225.md>`_
##

import
  std/[random, sequtils, strutils, times],
  ../../db/db_chain,
  ../../utils/ec_recover,
  ./clique_defs,
  eth/common,
  ethash,
  stew/results,
  stint

const
  prngSeed = 42

type
  SimpleTypePP = BlockNonce|EthAddress|Blob|BlockHeader
  SeqTypePP = EthAddress|BlockHeader

  PrettyPrintDefect* = object of Defect
    ## Defect raised with `pp()` problems, should be used for debugging only

  PrettyPrinters* = object ## Set of pretty printers for debugging
    nonce*: proc(v: BlockNonce):
                 string {.gcsafe,raises: [Defect,CatchableError].}
    address*: proc(v: EthAddress):
                 string {.gcsafe,raises: [Defect,CatchableError].}
    extraData*: proc(v: Blob):
                 string {.gcsafe,raises: [Defect,CatchableError].}
    blockHeader*: proc(v: BlockHeader; delim: string):
                 string {.gcsafe,raises: [Defect,CatchableError].}

  CliqueCfg* = ref object of RootRef
    db*: BaseChainDB ##\
      ## All purpose (incl. blockchain) database.

    period: Duration ##\
      ## Time between blocks to enforce.

    ckpInterval: int ##\
      ## Number of blocks after which to save the vote snapshot to the
      ## database.

    roThreshold: int ##\
      ## Number of blocks after which a chain segment is considered immutable
      ## (ie. soft finality). It is used by the downloader as a hard limit
      ## against deep ancestors, by the blockchain against deep reorgs, by the
      ## freezer as the cutoff threshold and by clique as the snapshot trust
      ## limit.

    prng: Rand ##\
      ## PRNG state for internal random generator. This PRNG is
      ## cryptographically insecure but with reproducible data stream.

    signatures: EcRecover ##\
      ## Recent block signatures cached to speed up mining.

    epoch: int ##\
      ## The number of blocks after which to checkpoint and reset the pending
      ## votes.Suggested 30000 for the testnet to remain analogous to the
      ## mainnet ethash epoch.

    logInterval: Duration ##\
      ## Time interval after which the `snapshotApply()` function main loop
      ## produces logging entries.

    debug*: bool ##\
      ## Debug mode flag

    prettyPrint*: PrettyPrinters ##\
      ## debugging support

{.push raises: [Defect].}

# ------------------------------------------------------------------------------
# Public constructor
# ------------------------------------------------------------------------------

proc newCliqueCfg*(db: BaseChainDB): CliqueCfg =
  result = CliqueCfg(
    db:          db,
    epoch:       EPOCH_LENGTH,
    period:      BLOCK_PERIOD,
    ckpInterval: CHECKPOINT_INTERVAL,
    roThreshold: FULL_IMMUTABILITY_THRESHOLD,
    logInterval: SNAPS_LOG_INTERVAL_MICSECS,
    signatures:  init(type EcRecover),
    prng:        initRand(prngSeed),
    prettyPrint: PrettyPrinters(
                   nonce:       proc(v:BlockNonce):                string = $v,
                   address:     proc(v:EthAddress):                string = $v,
                   extraData:   proc(v:Blob):                      string = $v,
                   blockHeader: proc(v:BlockHeader; delim:string): string = $v))

# ------------------------------------------------------------------------------
# Public helper funcion
# ------------------------------------------------------------------------------

# clique/clique.go(145): func ecrecover(header [..]
proc ecRecover*(cfg: CliqueCfg; header: BlockHeader): auto
                                   {.gcsafe, raises: [Defect,CatchableError].} =
  cfg.signatures.ecRecover(header)

# ------------------------------------------------------------------------------
# Public setters
# ------------------------------------------------------------------------------

proc `epoch=`*(cfg: CliqueCfg; epoch: SomeInteger) {.inline.} =
  ## Setter
  cfg.epoch = if 0 < epoch: epoch
              else: EPOCH_LENGTH

proc `period=`*(cfg: CliqueCfg; period: Duration)  {.inline.} =
  ## Setter
  cfg.period = if period != Duration(): period
               else: BLOCK_PERIOD

proc `ckpInterval=`*(cfg: CliqueCfg; numBlocks: SomeInteger) {.inline.} =
  ## Setter
  cfg.ckpInterval = if 0 < numBlocks: numBlocks
                    else: CHECKPOINT_INTERVAL

proc `roThreshold=`*(cfg: CliqueCfg; numBlocks: SomeInteger) {.inline.} =
  ## Setter
  cfg.roThreshold = if 0 < numBlocks: numBlocks
                    else: FULL_IMMUTABILITY_THRESHOLD

proc `logInterval=`*(cfg: CliqueCfg; duration: Duration)  {.inline.} =
  ## Setter
  cfg.logInterval = if duration != Duration(): duration
                    else: SNAPS_LOG_INTERVAL_MICSECS

# ------------------------------------------------------------------------------
# Public PRNG, may be overloaded
# ------------------------------------------------------------------------------

method rand*(cfg: CliqueCfg; max: Natural): int {.gcsafe,base.} =
  ## The method returns a random number base on an internal PRNG providing a
  ## reproducible stream of random data. This function is supposed to be used
  ## exactly when repeatability comes in handy. Never to be used for crypto key
  ## generation or like (except testing.)
  cfg.prng.rand(max)

# ------------------------------------------------------------------------------
# Public getter
# ------------------------------------------------------------------------------

proc epoch*(cfg: CliqueCfg): auto {.inline.} =
  ## Getter
  cfg.epoch.u256

proc period*(cfg: CliqueCfg): auto {.inline.} =
  ## Getter
  cfg.period

proc ckpInterval*(cfg: CliqueCfg): auto {.inline.} =
  ## Getter
  cfg.ckpInterval.u256

proc roThreshold*(cfg: CliqueCfg): auto {.inline.} =
  ## Getter
  cfg.roThreshold

proc logInterval*(cfg: CliqueCfg): auto {.inline.} =
  ## Getter
  cfg.logInterval

# ------------------------------------------------------------------------------
# Debugging
# ------------------------------------------------------------------------------

template ppExceptionWrap*(body: untyped) =
  ## Exception relay to `PrettyPrintDefect`, intended to be used with `pp()`
  ## related functions.
  try:
    body
  except:
    raise (ref PrettyPrintDefect)(msg: getCurrentException().msg)

proc say*(cfg: CliqueCfg; v: varargs[string,`$`]) {.inline.} =
  ## Debugging output
  ppExceptionWrap:
    if cfg.debug: stderr.write "*** " & v.join & "\n"


proc pp*(v: CliqueError): string =
  ## Pretty print error
  result = $v[0]
  if v[1] != "":
    result &=  " => " & v[1]

proc pp*(v: CliqueOkResult): string =
  ## Pretty print result
  if v.isOk:
    "OK"
  else:
    v.error.pp


proc pp*(p: var PrettyPrinters; v: BlockNonce): string =
  ## Pretty print nonce (for debugging)
  ppExceptionWrap: p.nonce(v)

proc pp*(p: var PrettyPrinters; v: EthAddress): string =
  ## Pretty print address (for debugging)
  ppExceptionWrap: p.address(v)

proc pp*(p: var PrettyPrinters; v: openArray[EthAddress]): seq[string] =
  ## Pretty print address list
  toSeq(v).mapIt(p.pp(it))

proc pp*(p: var PrettyPrinters; v: Blob): string =
  ## Visualise `extraData` field
  ppExceptionWrap: p.extraData(v)

proc pp*(p: var PrettyPrinters; v: BlockHeader; delim: string): string =
  ## Pretty print block header
  ppExceptionWrap: p.blockHeader(v, delim)

proc pp*(p: var PrettyPrinters; v: BlockHeader; indent = 3): string =
  ## Pretty print block header, NL delimited, indented fields
  let delim = if 0 < indent: "\n" & ' '.repeat(indent) else: " "
  p.pp(v,delim)

proc pp*(p: var PrettyPrinters; v: openArray[BlockHeader]): seq[string] =
  ## Pretty print list of block headers
  toSeq(v).mapIt(p.pp(it,","))


proc pp*[T;V: SimpleTypePP](t: T; v: V): string =
  ## Generic pretty printer, requires `getPrettyPrinters()` function:
  ## ::
  ##     proc getPrettyPrinters(t: SomeLocalType): var PrettyPrinters
  ##
  mixin getPrettyPrinters
  ppExceptionWrap: t.getPrettyPrinters.pp(v)

proc pp*[T;V: var SimpleTypePP](t: var T; v: V): string =
  ## Generic pretty printer, requires `getPrettyPrinters()` function:
  ## ::
  ##     proc getPrettyPrinters(t: var SomeLocalType): var PrettyPrinters
  ##
  mixin getPrettyPrinters
  ppExceptionWrap: t.getPrettyPrinters.pp(v)


proc pp*[T;V: SeqTypePP](t: T; v: openArray[V]): seq[string] =
  ## Generic pretty printer, requires `getPrettyPrinters()` function:
  ## ::
  ##     proc getPrettyPrinters(t: SomeLocalType): var PrettyPrinters
  ##
  mixin getPrettyPrinters
  ppExceptionWrap: t.getPrettyPrinters.pp(v)

proc pp*[T;V: SeqTypePP](t: var T; v: openArray[V]): seq[string] =
  ## Generic pretty printer, requires `getPrettyPrinters()` function:
  ## ::
  ##     proc getPrettyPrinters(t: var SomeLocalType): var PrettyPrinters
  ##
  mixin getPrettyPrinters
  ppExceptionWrap: t.getPrettyPrinters.pp(v)


proc pp*[T;X: int|string](t: T; v: BlockHeader; sep: X): string =
  ## Generic pretty printer, requires `getPrettyPrinters()` function:
  ## ::
  ##     proc getPrettyPrinters(t: SomeLocalType): var PrettyPrinters
  ##
  mixin getPrettyPrinters
  ppExceptionWrap: t.getPrettyPrinters.pp(v,sep)

proc pp*[T;X: int|string](t: var T; v: BlockHeader; sep: X): string =
  ## Generic pretty printer, requires `getPrettyPrinters()` function:
  ## ::
  ##     proc getPrettyPrinters(t: var SomeLocalType): var PrettyPrinters
  ##
  mixin getPrettyPrinters
  ppExceptionWrap: t.getPrettyPrinters.pp(v,sep)

# ------------------------------------------------------------------------------
# End
# ------------------------------------------------------------------------------
