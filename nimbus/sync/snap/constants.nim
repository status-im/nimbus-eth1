# Nimbus
# Copyright (c) 2021 Status Research & Development GmbH
# Licensed under either of
#  * Apache License, version 2.0, ([LICENSE-APACHE](LICENSE-APACHE) or
#    http://www.apache.org/licenses/LICENSE-2.0)
#  * MIT license ([LICENSE-MIT](LICENSE-MIT) or
#    http://opensource.org/licenses/MIT)
# at your option. This file may not be copied, modified, or distributed
# except according to those terms.

{.push raises: [Defect].}

const
  pivotBlockDistanceMin* = 128
    ## The minimal depth of two block headers needed to activate a new state
    ## root pivot.
    ##
    ## Effects on assembling the state via `snap/1` protocol:
    ##
    ## * A small value of this constant increases the propensity to update the
    ##   pivot header more often. This is so because each new peer negoiates a
    ##   pivot block number at least the current one.
    ##
    ## * A large value keeps the current pivot more stable but some experiments
    ##   suggest that the `snap/1` protocol is answered only for later block
    ##   numbers (aka pivot blocks.) So a large value tends to keep the pivot
    ##   farther away from the chain head.
    ##
    ##   Note that 128 is the magic distance for snapshots used by *Geth*.

  pivotEnvStopChangingIfComplete* = true
    ## If set `true`, new peers will not change the pivot even if the
    ## negotiated pivot would be newer. This should be the default.

  # --------------

  snapRequestBytesLimit* = 2 * 1024 * 1024
    ## Soft bytes limit to request in `snap` protocol calls.

  snapTrieNodeFetchMax* = 1024
    ## Informal maximal number of trie nodes to fetch at once. This is not
    ## an official limit but found on several implementations (e.g. Geth.)
    ##
    ## Resticting the fetch list length early allows to better paralellise
    ## healing.

  snapStoragesSlotsFetchMax* = 2 * 1024
    ## Maximal number of storage tries to fetch with a single message.

  # --------------

  healAccountsTrigger* = 0.95
    ## Apply accounts healing if the global snap download coverage factor
    ## exceeds this setting. The global coverage factor is derived by merging
    ## all account ranges retrieved for all pivot state roots (see
    ## `coveredAccounts` in `CtxData`.)
    ##
    ## A small value of this constant leads to early healing. This produces
    ## stray leaf account records so fragmenting larger intervals of missing
    ## account ranges. This in turn leads to smaller but more range requests
    ## over the network. More requests might be a disadvantage if peers only
    ## serve a maximum number requests (rather than data.)

  healSlorageSlotsTrigger* = 0.70
    ## Consider per account storage slost healing if a per-account hexary
    ## sub-trie has reached this factor of completeness.

  healStoragesSlotsBatchMax* = 32
    ## Maximal number of storage tries to to heal in a single batch run. Only
    ## this many items will be removed from the batch queue. These items will
    ## then be processed one by one.

  # --------------

  comErrorsTimeoutMax* = 4
    ## Maximal number of non-resonses accepted in a row. If there are more than
    ## `comErrorsTimeoutMax` consecutive errors, the worker will be degraded
    ## as zombie.

static:
  doAssert healAccountsTrigger < 1.0 # larger values make no sense

# ------------------------------------------------------------------------------
# End
# ------------------------------------------------------------------------------
