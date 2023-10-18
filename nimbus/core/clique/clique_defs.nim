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

import
  std/[times],
  eth/common,
  stew/results,
  stint

{.push raises: [].}

# ------------------------------------------------------------------------------
# Constants copied from eip-225 specs & implementation
# ------------------------------------------------------------------------------

const
  # clique/clique.go(48): const ( [..]
  CHECKPOINT_INTERVAL* = ##\
    ## Number of blocks after which to save the vote snapshot to the database
    4 * 1024

  INMEMORY_SNAPSHOTS* = ##\
    ## Number of recent vote snapshots to keep in memory.
    128

  WIGGLE_TIME* = ##\
    ## PoA mining only (currently unsupported).
    ##
    ## Random delay (per signer) to allow concurrent signers
    initDuration(seconds = 0, milliseconds = 500)

  # clique/clique.go(57): var ( [..]
  BLOCK_PERIOD* = ##\
    ## Minimum difference in seconds between two consecutive block timestamps.
    ## Suggested time is 15s for the `testnet` to remain analogous to the
    ## `mainnet` ethash target.
    EthTime 15

  EXTRA_VANITY* = ##\
    ## Fixed number of extra-data prefix bytes reserved for signer vanity.
    ## Suggested 32 bytes to retain the current extra-data allowance and/or use.
    32

  NONCE_AUTH* = ##\
    ## Magic nonce number 0xffffffffffffffff to vote on adding a new signer.
    0xffffffffffffffffu64.toBlockNonce

  NONCE_DROP* = ##\
    ## Magic nonce number 0x0000000000000000 to vote on removing a signer.
    0x0000000000000000u64.toBlockNonce

  DIFF_NOTURN* = ##\
    ## Block score (difficulty) for blocks containing out-of-turn signatures.
    ## Suggested 1 since it just needs to be an arbitrary baseline constant.
    1.u256

  DIFF_INTURN* = ##\
    ## Block score (difficulty) for blocks containing in-turn signatures.
    ## Suggested 2 to show a slight preference over out-of-turn signatures.
    2.u256

  # params/network_params.go(60): FullImmutabilityThreshold = 90000
  FULL_IMMUTABILITY_THRESHOLD* = ##\
    ## Number of blocks after which a chain segment is considered immutable (ie.
    ## soft finality). It is used by the downloader as a hard limit against
    ## deep ancestors, by the blockchain against deep reorgs, by the freezer as
    ## the cutoff threshold and by clique as the snapshot trust limit.
    90000

  # Other
  SNAPS_LOG_INTERVAL_MICSECS* = ##\
    ##  Time interval after which the `snapshotApply()` function main loop
    ## produces logging entries. The original value from the Go reference
    ## implementation has 8 seconds (which seems a bit long.) For the first
    ## 300k blocks in the Goerli chain, typical execution time in tests was
    ## mostly below 300 micro secs.
    initDuration(microSeconds = 200)

# ------------------------------------------------------------------------------
# Error tokens
# ------------------------------------------------------------------------------

type
  # clique/clique.go(76): var ( [..]
  CliqueErrorType* = enum
    resetCliqueError = ##\
      ## Default/reset value (use `cliqueNoError` below rather than this valie)
      (0, "no error")

    errUnknownBlock =  ##\
      ## is returned when the list of signers is requested for a block that is
      ## not part of the local blockchain.
      "unknown block"

    errInvalidCheckpointBeneficiary = ##\
      ## is returned if a checkpoint/epoch transition block has a beneficiary
      ## set to non-zeroes.
      "beneficiary in checkpoint block non-zero"

    errInvalidVote = ##\
      ## is returned if a nonce value is something else that the two allowed
      ## constants of 0x00..0 or 0xff..f.
      "vote nonce not 0x00..0 or 0xff..f"

    errInvalidCheckpointVote = ##\
      ## is returned if a checkpoint/epoch transition block has a vote nonce
      ## set to non-zeroes.
      "vote nonce in checkpoint block non-zero"

    errMissingVanity = ##\
      ## is returned if a block's extra-data section is shorter than 32 bytes,
      ## which is required to store the signer vanity.
      "extra-data 32 byte vanity prefix missing"

    errMissingSignature = ##\
      ## is returned if a block's extra-data section doesn't seem to contain a
      ## 65 byte secp256k1 signature.
      "extra-data 65 byte signature suffix missing"

    errExtraSigners = ##\
      ## is returned if non-checkpoint block contain signer data in their
      ## extra-data fields.
      "non-checkpoint block contains extra signer list"

    errInvalidCheckpointSigners = ##\
      ## is returned if a checkpoint block contains an invalid list of signers
      ## (i.e. non divisible by 20 bytes).
      "invalid signer list on checkpoint block"

    errMismatchingCheckpointSigners = ##\
      ## is returned if a checkpoint block contains a list of signers different
      ## than the one the local node calculated.
      "mismatching signer list on checkpoint block"

    errInvalidMixDigest = ##\
      ## is returned if a block's mix digest is non-zero.
      "non-zero mix digest"

    errInvalidUncleHash = ##\
      ## is returned if a block contains an non-empty uncle list.
      "non empty uncle hash"

    errInvalidDifficulty = ##\
      ## is returned if the difficulty of a block neither 1 or 2.
      "invalid difficulty"

    errWrongDifficulty = ##\
      ## is returned if the difficulty of a block doesn't match the turn of
      ## the signer.
      "wrong difficulty"

    errInvalidTimestamp = ##\
      ## is returned if the timestamp of a block is lower than the previous
      ## block's timestamp + the minimum block period.
      "invalid timestamp"

    errInvalidVotingChain = ##\
      ## is returned if an authorization list is attempted to be modified via
      ## out-of-range or non-contiguous headers.
      "invalid voting chain"

    errUnauthorizedSigner = ##\
      ## is returned if a header is signed by a non-authorized entity.
      "unauthorized signer"

    errRecentlySigned = ##\
      ## is returned if a header is signed by an authorized entity that
      ## already signed a header recently, thus is temporarily not allowed to.
      "recently signed"


    # additional errors sources elsewhere
    # -----------------------------------

    errPublicKeyToShort = ##\
      ## Cannot retrieve public key
      "cannot retrieve public key: too short"

    # imported from consensus/errors.go
    errUnknownAncestor = ##\
      ## is returned when validating a block requires an ancestor that is
      ## unknown.
      "unknown ancestor"

    errFutureBlock = ##\
      ## is returned when a block's timestamp is in the future according to
      ## the current node.
      "block in the future"

    # additional/bespoke errors, manually added
    # -----------------------------------------

    errUnknownHash = "No header found for hash value"
    errEmptyLruCache = "No snapshot available"

    errNotInitialised = ##\
      ## Initalisation value for `Result` entries
      "Not initialised"

    errSetLruSnaps = ##\
      ## Attempt to assign a value to a non-existing slot
      "Missing LRU slot for snapshot"

    errEcRecover = ##\
      ## Subsytem error"
      "ecRecover failed"

    errSnapshotLoad               ## DB subsytem error
    errSnapshotStore              ## ..
    errSnapshotClone

    errCliqueGasLimitOrBaseFee
    errCliqueExceedsGasLimit
    errCliqueGasRepriceFork
    errCliqueSealSigFn

    errCliqueStopped = "process was interrupted"
    errCliqueUnclesNotAllowed = "uncles not allowed"

    # not really an error
    nilCliqueSealNoBlockYet = "Sealing paused, waiting for transactions"
    nilCliqueSealSignedRecently = "Signed recently, must wait for others"

# ------------------------------------------------------------------------------
# More types and constants
# ------------------------------------------------------------------------------

type
  CliqueError* = ##\
    ## Error message, tinned component + explanatory text (if any)
    (CliqueErrorType,string)

  CliqueOkResult* = ##\
    ## Standard ok/error result type for `Clique` functions
    Result[void,CliqueError]

const
  cliqueNoError* = ##\
    ## No-error constant
    (resetCliqueError, "")

# ------------------------------------------------------------------------------
# End
# ------------------------------------------------------------------------------
