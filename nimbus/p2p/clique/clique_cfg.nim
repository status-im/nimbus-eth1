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
  ../../db/db_chain,
  ./clique_defs,
  ./ec_recover,
  eth/common,
  ethash,
  random,
  sequtils,
  stint,
  strutils,
  times

const
  prngSeed = 42

type
  SimpleTypePP = BlockNonce|EthAddress|Blob|BlockHeader
  SeqTypePP = EthAddress|BlockHeader

  PrettyPrinters* = object
    nonce*: proc(v: BlockNonce):
                 string {.gcsafe,raises: [Defect,CatchableError].}
    address*: proc(v: EthAddress):
                 string {.gcsafe,raises: [Defect,CatchableError].}
    extraData*: proc(v: Blob):
                 string {.gcsafe,raises: [Defect,CatchableError].}
    blockHeader*: proc(v: BlockHeader; delim: string):
                 string {.gcsafe,raises: [Defect,CatchableError].}

  CliqueCfg* = ref object
    dbChain*: BaseChainDB
    signatures*: EcRecover  ## Recent block signatures to speed up mining
    period*: Duration       ## time between blocks to enforce
    prng*: Rand             ## PRNG state for internal random generator
    epoch*: UInt256         ## The number of blocks after which to checkpoint
                            ## and reset the pending votes.Suggested 30000 for
                            ## the testnet to remain analogous to the mainnet
                            ## ethash epoch.
    prettyPrint*: PrettyPrinters ## debugging support

{.push raises: [Defect,CatchableError].}

# ------------------------------------------------------------------------------
# Public functions
# ------------------------------------------------------------------------------

proc newCliqueCfg*(dbChain: BaseChainDB; period = BLOCK_PERIOD;
                   epoch = 0.u256): CliqueCfg =
  CliqueCfg(
    dbChain:     dbChain,
    period:      period,
    epoch:       if epoch.isZero: EPOCH_LENGTH.u256 else: epoch,
    signatures:  initEcRecover(),
    prng:        initRand(prngSeed),
    prettyPrint: PrettyPrinters(
                   nonce:       proc(v:BlockNonce):                string = $v,
                   address:     proc(v:EthAddress):                string = $v,
                   extraData:   proc(v:Blob):                      string = $v,
                   blockHeader: proc(v:BlockHeader; delim:string): string = $v))

# ------------------------------------------------------------------------------
# Debugging
# ------------------------------------------------------------------------------

proc pp*(p: var PrettyPrinters; v: BlockNonce): string =
  ## Pretty print nonce
  p.nonce(v)

proc pp*(p: var PrettyPrinters; v: EthAddress): string =
  ## Pretty print address
  p.address(v)

proc pp*(p: var PrettyPrinters; v: openArray[EthAddress]): seq[string] =
  ## Pretty print address list
  toSeq(v).mapIt(p.pp(it))

proc pp*(p: var PrettyPrinters; v: Blob): string =
  ## Visualise `extraData` field
  p.extraData(v)

proc pp*(p: var PrettyPrinters; v: BlockHeader; delim: string): string =
  ## Pretty print block header
  p.blockHeader(v, delim)

proc pp*(p: var PrettyPrinters; v: BlockHeader; indent = 3): string =
  ## Pretty print block header, NL delimited, indented fields
  let delim = if 0 < indent: "\n" & ' '.repeat(indent) else: " "
  p.pp(v,delim)

proc pp*(p: var PrettyPrinters; v: openArray[BlockHeader]): seq[string] =
  ## Pretty print list of block headers
  toSeq(v).mapIt(p.pp(it,","))


proc pp*[T;V: SimpleTypePP](t: T; v: V): string =
  ## Generic prtetty printer, requires `getPrettyPrinters()` function:
  ## ::
  ##     proc getPrettyPrinters(t: SomeLocalType): var PrettyPrinters
  ##
  mixin getPrettyPrinters
  t.getPrettyPrinters.pp(v)

proc pp*[T;V: var SimpleTypePP](t: var T; v: V): string =
  ## Generic prtetty printer, requires `getPrettyPrinters()` function:
  ## ::
  ##     proc getPrettyPrinters(t: var SomeLocalType): var PrettyPrinters
  ##
  mixin getPrettyPrinters
  t.getPrettyPrinters.pp(v)


proc pp*[T;V: SeqTypePP](t: T; v: openArray[V]): seq[string] =
  ## Generic prtetty printer, requires `getPrettyPrinters()` function:
  ## ::
  ##     proc getPrettyPrinters(t: SomeLocalType): var PrettyPrinters
  ##
  mixin getPrettyPrinters
  t.getPrettyPrinters.pp(v)

proc pp*[T;V: SeqTypePP](t: var T; v: openArray[V]): seq[string] =
  ## Generic prtetty printer, requires `getPrettyPrinters()` function:
  ## ::
  ##     proc getPrettyPrinters(t: var SomeLocalType): var PrettyPrinters
  ##
  mixin getPrettyPrinters
  t.getPrettyPrinters.pp(v)


proc pp*[T;X: int|string](t: T; v: BlockHeader; sep: X): string =
  ## Generic prtetty printer, requires `getPrettyPrinters()` function:
  ## ::
  ##     proc getPrettyPrinters(t: SomeLocalType): var PrettyPrinters
  ##
  mixin getPrettyPrinters
  t.getPrettyPrinters.pp(v,sep)

proc pp*[T;X: int|string](t: var T; v: BlockHeader; sep: X): string =
  ## Generic prtetty printer, requires `getPrettyPrinters()` function:
  ## ::
  ##     proc getPrettyPrinters(t: var SomeLocalType): var PrettyPrinters
  ##
  mixin getPrettyPrinters
  t.getPrettyPrinters.pp(v,sep)

# ------------------------------------------------------------------------------
# End
# ------------------------------------------------------------------------------
