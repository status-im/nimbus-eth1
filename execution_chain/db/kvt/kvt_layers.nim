# nimbus-eth1
# Copyright (c) 2023-2026 Status Research & Development GmbH
# Licensed under either of
#  * Apache License, version 2.0, ([LICENSE-APACHE](LICENSE-APACHE) or
#    http://www.apache.org/licenses/LICENSE-2.0)
#  * MIT license ([LICENSE-MIT](LICENSE-MIT) or
#    http://opensource.org/licenses/MIT)
# at your option. This file may not be copied, modified, or distributed
# except according to those terms.

{.push raises: [].}

import
  std/[sets, tables],
  results,
  ./kvt_desc,
  ../../utils/mergeutils

# ------------------------------------------------------------------------------
# Public functions: get function
# ------------------------------------------------------------------------------

func layersLen*(db: KvtTxRef; key: openArray[byte]|seq[byte]): Opt[int] =
  ## Returns the size of the value associated with `key`.
  ##
  when key isnot seq[byte]:
    let key = @key

  for w in db.rstack:
    w.sTab.withValue(key, item):
      return Opt.some(item[].len())

  Opt.none(int)

func layersHasKey*(db: KvtTxRef; key: openArray[byte]|seq[byte]): bool =
  ## Return `true` if the argument key is cached.
  ##
  db.layersLen(key).isSome()

func layersGet*(db: KvtTxRef; key: openArray[byte]|seq[byte]): Opt[seq[byte]] =
  ## Find an item on the cache layers. An `ok()` result might contain an
  ## empty value if it is stored on the cache  that way.
  ##
  when key isnot seq[byte]:
    let key = @key

  for w in db.rstack:
    w.sTab.withValue(key, item):
      return Opt.some(item[])

  Opt.none(seq[byte])

# ------------------------------------------------------------------------------
# Public functions: put function
# ------------------------------------------------------------------------------

func layersPut*(db: KvtTxRef; key: openArray[byte]; data: openArray[byte]) =
  ## Store a (potentally empty) value on the top layer
  db.sTab[@key] = @data

# ------------------------------------------------------------------------------
# Public functions
# ------------------------------------------------------------------------------

proc mergeAndReset*(trg, src: KvtTxRef) =
  mergeAndReset(trg.sTab, src.sTab)

# ------------------------------------------------------------------------------
# End
# ------------------------------------------------------------------------------
