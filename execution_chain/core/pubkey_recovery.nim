# Nimbus
# Copyright (c) 2026 Status Research & Development GmbH
# Licensed under either of
#  * Apache License, version 2.0, ([LICENSE-APACHE](LICENSE-APACHE))
#  * MIT license ([LICENSE-MIT](LICENSE-MIT))
# at your option.
# This file may not be copied, modified, or distributed except according to
# those terms.

## Public key recovery, in the one form both the software implementation and the
## zkVM accelerator produce.

{.push raises: [], gcsafe.}

import results, eth/common/[hashes, keys], ../compile_info

when enable_zkvm_accelerators:
  import ../stateless/zkvm/zkvm_accelerators

export hashes, keys, results

func recoverPubkeyRaw*(msgHash: Hash32, sig: Signature): Opt[array[64, byte]] =
  ## Recover the signer of `msgHash` as the key's coordinates `x ‖ y`.
  when enable_zkvm_accelerators:
    let raw = sig.toRaw() # r ‖ s ‖ recid
    var pubkey {.noinit.}: array[64, byte]
    if not ecRecoverRaw(msgHash.data, raw.toOpenArray(0, 63), raw[64], pubkey):
      return Opt.none(array[64, byte])
    Opt.some(pubkey)
  else:
    let pubkey = recover(sig, SkMessage(msgHash.data)).valueOr:
      return Opt.none(array[64, byte])
    Opt.some(pubkey.toRaw())

func recoverPubkeyRaw*(msgHash: Hash32, sig: array[65, byte]): Opt[array[64, byte]] =
  ## As above, for a signature still in its `r ‖ s ‖ recid` bytes.
  when enable_zkvm_accelerators:
    var pubkey {.noinit.}: array[64, byte]
    if not ecRecoverRaw(msgHash.data, sig.toOpenArray(0, 63), sig[64], pubkey):
      return Opt.none(array[64, byte])
    Opt.some(pubkey)
  else:
    let parsed = Signature.fromRaw(sig).valueOr:
      return Opt.none(array[64, byte])
    recoverPubkeyRaw(msgHash, parsed)
