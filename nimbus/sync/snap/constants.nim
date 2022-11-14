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

  snapStoragesSlotsFetchMax* = 2 * 1024
    ## Maximal number of storage tries to fetch with a single message.

  snapTrieNodeFetchMax* = 1024
    ## Informal maximal number of trie nodes to fetch at once. This is not
    ## an official limit but found on several implementations (e.g. Geth.)
    ##
    ## Resticting the fetch list length early allows to better paralellise
    ## healing.

  snapAccountsHealBatchFetchMax* = 5 * snapTrieNodeFetchMax
    ## Keap on gloing in healing task up until this many nodes have been
    ## fetched from the network or some error contition therminates the task.

  snapNewBuddyStoragesSlotsQuPrioThresh* = 5_000
    ## For a new worker, prioritise processing the storage slots queue over
    ## processing accounts if the queue has more than this many items.

  snapStorageSlotsQuPrioThresh* = 30_000
    ## For a running worker processing accounts, stop processing accounts
    ## and switch to processing the storage slots queue if the queue has
    ## more than this many items.
  
  # --------------

  healAccountsTrigger* = 0.99
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

  healAccountsInspectionBatch* = 10_000
    ## Number of nodes to inspect in a single batch. Several batches are run
    ## until at least `snapTrieNodeFetchMax` dangling nodes are found. In
    ## between batches, a tast/thread switch is allowed.

  healSlorageSlotsTrigger* = 0.70
    ## Consider per account storage slost healing if a per-account hexary
    ## sub-trie has reached this factor of completeness.

  healStorageSlotsInspectionBatch* = 10_000
    ## Similar to `healAccountsInspectionBatch` but for storage slots.

  healStoragesSlotsBatchMax* = 32
    ## Maximal number of storage tries to to heal in a single batch run. Only
    ## this many items will be removed from the batch queue. These items will
    ## then be processed one by one.

  # --------------

  comErrorsTimeoutMax* = 3
    ## Maximal number of non-resonses accepted in a row. If there are more than
    ## `comErrorsTimeoutMax` consecutive errors, the worker will be degraded
    ## as zombie.

  comErrorsTimeoutSleepMSecs* = 5000
    ## Wait/suspend for this many seconds after a timeout error if there are
    ## not more than `comErrorsTimeoutMax` errors in a row (maybe some other
    ## network or no-data errors mixed in.) Set 0 to disable.


  comErrorsNetworkMax* = 5
    ## Similar to `comErrorsTimeoutMax` but for network errors.

  comErrorsNetworkSleepMSecs* = 5000
    ## Similar to `comErrorsTimeoutSleepSecs` but for network errors.
    ## Set 0 to disable.

  comErrorsNoDataMax* = 3
    ## Similar to `comErrorsTimeoutMax` but for missing data errors.

  comErrorsNoDataSleepMSecs* = 0
    ## Similar to `comErrorsTimeoutSleepSecs` but for missing data errors.
    ## Set 0 to disable.

static:
  doAssert healAccountsTrigger < 1.0 # larger values make no sense

# ------------------------------------------------------------------------------
# End
# ------------------------------------------------------------------------------
