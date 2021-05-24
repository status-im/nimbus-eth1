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
## Clique PoA Constants & Types
## ============================
##
## Constants used by Clique proof-of-authority consensus protocol, see
## `EIP-225 <https://github.com/ethereum/EIPs/blob/master/EIPS/eip-225.md>`_
## and
## `go-ethereum <https://github.com/ethereum/EIPs/blob/master/EIPS/eip-225.md>`_
##

const
   # debugging, enable with: nim c -r -d:noisy:3 ...
   noisy {.intdefine.}: int = 0
   isMainOk {.used.} = noisy > 2

import
  eth/common,
  ethash,
  nimcrypto,
  stew/results,
  times

# ------------------------------------------------------------------------------
# Constants copied from eip-225 specs
# ------------------------------------------------------------------------------

const
  EPOCH_LENGTH* = ## Number of blocks after which to checkpoint and reset
                  ## the pending votes.Suggested 30000 for the testnet to
                  ## remain analogous to the mainnet ethash epoch.
    ethash.EPOCH_LENGTH

  BLOCK_PERIOD* = ## Minimum difference in seconds between two consecutive
                  ## block's timestamps. Suggested 15s for the testnet to
                  ## remain analogous to the mainnet ethash target.
    15

  EXTRA_VANITY* = ## Fixed number of extra-data prefix bytes reserved for
                  ## signer vanity. Suggested 32 bytes to retain the current
                  ## extra-data allowance and/or use.
    32

  EXTRA_SEAL* =   ## Fixed number of extra-data suffix bytes reserved for
                  ## signer seal. 65 bytes fixed as signatures are based on
                  ## the standard secp256k1 curve.
    65

  NONCE_AUTH* =   ## Magic nonce number 0xffffffffffffffff to vote on adding a
                  ## new signer.
    0xffffffffffffffffu64

  NONCE_DROP* =   ## Magic nonce number 0x0000000000000000 to vote on removing
                  ## a signer.
    0x0000000000000000u64

  UNCLE_HASH* =   ## Always Keccak256(RLP([])) as uncles are meaningless
                  ## outside of PoW.
    rlpHash[seq[BlockHeader]](@[])

  DIFF_NOTURN* =  ## Block score (difficulty) for blocks containing out-of-turn
                  ## signatures. Suggested 1 since it just needs to be an
                  ## arbitrary baseline constant.
    1

  DIFF_INTURN* =  ## Block score (difficulty) for blocks containing in-turn
                  ## signatures. Suggested 2 to show a slight preference over
                  ## out-of-turn signatures.
    2

# We also define the following per-block constants:
#
#  BLOCK_NUMBER* = ## Block height in the chain, where the height of the genesis
#                  ## is block 0.
#    n/n
#
#  SIGNER_COUNT* = ## Number of authorized signers valid at a particular
#                  ## instance in the chain.
#    n/n
#
#  SIGNER_INDEX* = ## Index of the block signer in the sorted list of current
#                  ## authorized signers.
#    n/n
#
#  SIGNER_LIMIT* = ## Number of consecutive blocks out of which a signer may
#                  ## only sign one. Must be floor(SIGNER_COUNT / 2) + 1 to
#                  ## enforce majority consensus on a chain.
#    (SIGNER_COUNT div 2) + 1

# ------------------------------------------------------------------------------
# Additional constants copied from eip-225 go implementation
# ------------------------------------------------------------------------------

const
  CHECKPOINT_INTERVAL* = ## Number of blocks after which to save the vote
                         ## snapshot to the database
    1024

  INMEMORY_SNAPSHOTS* =  ## Number of recent vote snapshots to keep in memory
    128

  INMEMORY_SIGNATURES* = ## Number of recent block signatures to keep in memory
     4096

  WIGGLE_TIME* =         ## Random delay (per signer) to allow concurrent
                         ## signers
    initDuration(seconds = 0, milliseconds = 500)

  nilCStr* =             ## handy helper
    cstring("")

# ------------------------------------------------------------------------------
# Error tokens
# ------------------------------------------------------------------------------

type
  CliqueErrorType* = enum
    errUnknownBlock =             ## is returned when the list of signers is
                                  ## requested for a block that is not part of
                                  ## the local blockchain.
      "unknown block"

    errInvalidCheckpointBeneficiary = ## is returned if a checkpoint/epoch
                                      ## transition block has a beneficiary
                                      ## set to non-zeroes.
      "beneficiary in checkpoint block non-zero"

    errInvalidVote =              ## is returned if a nonce value is something
                                  ## else that the two allowed constants of
                                  ## 0x00..0 or 0xff..f.
      "vote nonce not 0x00..0 or 0xff..f"

    errInvalidCheckpointVote =    ## is returned if a checkpoint/epoch
                                  ## transition block has a vote nonce set to
                                  ## non-zeroes.
      "vote nonce in checkpoint block non-zero"

    errMissingVanity =            ## is returned if a block's extra-data section
                                  ## is shorter than 32 bytes, which is required
                                  ## to store the signer vanity.
      "extra-data 32 byte vanity prefix missing"

    errMissingSignature =         ## is returned if a block's extra-data section
                                  ## doesn't seem to contain a 65 byte secp256k1
                                  ## signature.
      "extra-data 65 byte signature suffix missing"

    errExtraSigners =             ## is returned if non-checkpoint block contain
                                  ## signer data in their extra-data fields.
      "non-checkpoint block contains extra signer list"

    errInvalidCheckpointSigners = ## is returned if a checkpoint block contains
                                  ## an invalid list of signers (i.e. non
                                  ## divisible by 20 bytes).
      "invalid signer list on checkpoint block"

    errMismatchingCheckpointSigners = ## is returned if a checkpoint block
                                      ## contains a list of signers different
                                      ## than the one the local node calculated.
      "mismatching signer list on checkpoint block"

    errInvalidMixDigest =         ## is returned if a block's mix digest is
                                  ## non-zero.
      "non-zero mix digest"

    errInvalidUncleHash =         ## is returned if a block contains an
                                  ## non-empty uncle list.
      "non empty uncle hash"

    errInvalidDifficulty =        ## is returned if the difficulty of a block
                                  ## neither 1 or 2.
      "invalid difficulty"

    errWrongDifficulty =          ## is returned if the difficulty of a block
                                  ## doesn't match the turn of the signer.
      "wrong difficulty"

    errInvalidTimestamp =         ## is returned if the timestamp of a block is
                                  ## lower than the previous block's timestamp
                                  ## + the minimum block period.
      "invalid timestamp"

    errInvalidVotingChain =       ## is returned if an authorization list is
                                  ## attempted to be modified via out-of-range
                                  ## or non-contiguous headers.
      "invalid voting chain"

    errUnauthorizedSigner =       ## is returned if a header is signed by a
                                  ## non-authorized entity.
      "unauthorized signer"

    errRecentlySigned =           ## is returned if a header is signed by an
                                  ## authorized entity that already signed a
                                  ## header recently, thus is temporarily not
                                  ## allowed to.
      "recently signed"

    errPublicKeyToShort =         ## Cannot retrieve public key
      "cannot retrieve public key: too short"

    errSkSigResult,               ## eth/keys subsytem error: signature
    errSkPubKeyResult,            ## eth/keys subsytem error: public key

# ------------------------------------------------------------------------------
# More types
# ------------------------------------------------------------------------------

type
  CliqueError* = (CliqueErrorType,cstring)
  CliqueResult* = Result[void,CliqueError]

  CliqueConfig* = object
    period: uint64          ## Number of seconds between blocks to enforce
    epoch:  uint64          ## Epoch length to reset votes and checkpoint

# ------------------------------------------------------------------------------
# Debugging
# ------------------------------------------------------------------------------

when isMainModule and isMainOK:

  # see comment at UNCLE_HASH
  import
    eth/rlp

  # FIXME: nim bails out with an error when using char or int8.

  doAssert rlp.encode[seq[BlockHeader]](@[]) == @[192.byte]
  doAssert rlp.encode[seq[BlockBody]](@[])   == @[192.byte]
  doAssert rlp.encode[seq[uint16]](@[])      == @[192.byte]

  doAssert rlp.encode[seq[byte]](@[])        == @[128.byte]
  doAssert rlp.encode[seq[byte]](@[1.byte])  ==   @[1.byte]
  doAssert rlp.encode[byte](1.byte)          ==   @[1.byte]

  echo OK

# ------------------------------------------------------------------------------
# End
# ------------------------------------------------------------------------------
