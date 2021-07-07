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
  ./clique_cfg/ec_recover,
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


  CliqueCfg* = ref object
    db*: BaseChainDB
    period*: Duration      ## time between blocks to enforce
    prng*: Rand            ## PRNG state for internal random generator

    signatures: EcRecover  ## Recent block signatures cached to speed up mining
    bcEpoch: UInt256       ## The number of blocks after which to checkpoint
                           ## and reset the pending votes.Suggested 30000 for
                           ## the testnet to remain analogous to the mainnet
                           ## ethash epoch.
    prettyPrint*: PrettyPrinters ## debugging support

{.push raises: [Defect].}

# ------------------------------------------------------------------------------
# Public constructor
# ------------------------------------------------------------------------------

proc newCliqueCfg*(db: BaseChainDB; period = BLOCK_PERIOD;
                   epoch = 0.u256): CliqueCfg =
  CliqueCfg(
    db:          db,
    period:      period,
    bcEpoch:     if epoch.isZero: EPOCH_LENGTH.u256 else: epoch,
    signatures:  initEcRecover(),
    prng:        initRand(prngSeed),
    prettyPrint: PrettyPrinters(
                   nonce:       proc(v:BlockNonce):                string = $v,
                   address:     proc(v:EthAddress):                string = $v,
                   extraData:   proc(v:Blob):                      string = $v,
                   blockHeader: proc(v:BlockHeader; delim:string): string = $v))

# ------------------------------------------------------------------------------
# Public helper funcion
# ------------------------------------------------------------------------------

proc ecRecover*(cfg: CliqueCfg; header: BlockHeader): auto
                                   {.gcsafe, raises: [Defect,CatchableError].}=
  cfg.signatures.getEcRecover(header)

# ------------------------------------------------------------------------------
# Public getter
# ------------------------------------------------------------------------------

proc epoch*(cfg: CliqueCfg): BlockNumber {.inline.} =
  ## Getter
  cfg.bcEpoch

# ------------------------------------------------------------------------------
# Public setters
# ------------------------------------------------------------------------------

proc `epoch=`*(cfg: CliqueCfg; epoch: BlockNumber) {.inline.} =
  ## Setter
  cfg.bcEpoch = epoch
  if cfg.bcEpoch.isZero:
    cfg.bcEpoch = EPOCH_LENGTH.u256

proc `epoch=`*(cfg: CliqueCfg; epoch: SomeUnsignedInt) {.inline.} =
  ## Setter
  cfg.epoch = epoch.u256

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


proc pp*(v: CliqueError): string =
  ## Pretty print error
  result = $v[0]
  if v[1] != "":
    result &=  " => " & v[1]

proc pp*(v: CliqueResult): string =
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
