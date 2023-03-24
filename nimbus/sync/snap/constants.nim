# Nimbus
# Copyright (c) 2021 Status Research & Development GmbH
# Licensed under either of
#  * Apache License, version 2.0, ([LICENSE-APACHE](LICENSE-APACHE) or
#    http://www.apache.org/licenses/LICENSE-2.0)
#  * MIT license ([LICENSE-MIT](LICENSE-MIT) or
#    http://opensource.org/licenses/MIT)
# at your option. This file may not be copied, modified, or distributed
# except according to those terms.

{.push raises: [].}

import
  eth/[common, trie/nibbles]

const
  EmptyBlob* = seq[byte].default
    ## Useful shortcut

  EmptyBlobSeq* = seq[Blob].default
    ## Useful shortcut

  EmptyNibbleSeq* = EmptyBlob.initNibbleRange
    ## Useful shortcut

  # ---------

  pivotTableLruEntriesMax* = 50
    ## Max depth of pivot table. On overflow, the oldest one will be removed.

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

  # --------------

  fetchRequestBytesLimit* = 2 * 1024 * 1024
    ## Soft bytes limit to request in `snap/1` protocol calls.

  fetchRequestTrieNodesMax* = 1024
    ## Informal maximal number of trie nodes to fetch at once in `snap/1`
    ## protocol calls. This is not an official limit but found with several
    ## implementations (e.g. Geth.)
    ##
    ## Resticting the fetch list length early allows to better parallelise
    ## healing.

  fetchRequestStorageSlotsMax* = 2 * 1024
    ## Maximal number of storage tries to fetch with a single request message.

  # --------------

  accountsFetchRetryMax* = 2
    ## The request intervals will be slightly re-arranged after failure.
    ## So re-trying to fetch another range might be successful (set to 0
    ## for disabling retries.)

  accountsSaveProcessedChunksMax* = 1000
    ## Recovery data are stored if the processed ranges list contains no more
    ## than this many range *chunks*.
    ##
    ## If the range set is too much fragmented, no data will be saved and
    ## restart has to perform from scratch or an earlier checkpoint.

  accountsSaveStorageSlotsMax* = 20_000
    ## Recovery data are stored if the oustanding storage slots to process do
    ## not amount to more than this many entries.
    ##
    ## If there are too many dangling nodes, no data will be saved and restart
    ## has to perform from scratch or an earlier checkpoint.


  storageSlotsTrieInheritPerusalMax* = 30_000
    ## Maximal number of nodes to visit in order to find out whether this
    ## storage slots trie is complete. This allows to *inherit* the full trie
    ## for an existing root node if the trie is small enough.

  storageSlotsQuPrioThresh* = 5_000
    ## For a new worker, prioritise processing the storage slots queue over
    ## processing accounts if the queue has more than this many items.
    ##
    ## For a running worker processing accounts, stop processing accounts
    ## and switch to processing the storage slots queue if the queue has
    ## more than this many items.

  # --------------

  healAccountsCoverageTrigger* = 1.01
    ## Apply accounts healing if the global snap download coverage factor
    ## exceeds this setting. The global coverage factor is derived by merging
    ## all account ranges retrieved for all pivot state roots (see
    ## `coveredAccounts` in the object `CtxData`.) Note that a coverage factor
    ## greater than 100% is not exact but rather a lower bound estimate.

  healAccountsInspectionPlanBLevel* = 4
    ## Search this level deep for missing nodes if `hexaryEnvelopeDecompose()`
    ## only produces existing nodes.
    ##
    ## The maximal number of nodes visited at level 3 is *4KiB* and at level 4
    ## is *64Kib*.

  healAccountsBatchMax* = 10 * 1024
    ## Keep on gloing in healing task up until this many nodes have been
    ## fetched from the network or some error contition terminates the task.
    ##
    ## This constant should be larger than `fetchRequestStorageSlotsMax`


  healSlorageSlotsTrigger* = 0.70
    ## Consider per account storage slost healing if a per-account hexary
    ## sub-trie has reached this factor of completeness.

  healStorageSlotsInspectionPlanBLevel* = 4
    ## Similar to `healAccountsInspectionPlanBLevel`

  healStorageSlotsBatchMax* = 32
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
  doAssert storageSlotsQuPrioThresh < accountsSaveStorageSlotsMax
  doAssert fetchRequestTrieNodesMax < healAccountsBatchMax


# Deprecated, to be expired
const
  healInspectionBatch* = 10_000
    ## Number of nodes to inspect in a single batch. In between batches, a
    ## task/thread switch is allowed.

  healInspectionBatchWaitNanoSecs* = 500
    ## Wait some time asynchroneously after processing `healInspectionBatch`
    ## nodes to allow for a pseudo -task switch.

# ------------------------------------------------------------------------------
# End
# ------------------------------------------------------------------------------
