# Nimbus
# Copyright (c) 2018 Status Research & Development GmbH
# Licensed under either of
#  * Apache License, version 2.0, ([LICENSE-APACHE](LICENSE-APACHE) or
#    http://www.apache.org/licenses/LICENSE-2.0)
#  * MIT license ([LICENSE-MIT](LICENSE-MIT) or
#    http://opensource.org/licenses/MIT)
# at your option. This file may not be copied, modified, or distributed except
# according to those terms.

## Transaction Pool Meters
## =======================
##

import
  metrics

# ------------------------------------------------------------------------------
# Private settings
# ------------------------------------------------------------------------------

# Metrics for the pending pool

# core/tx_pool.go(97): pendingDiscardMeter = metrics.NewRegisteredMeter(..
declareGauge pendingDiscard, "n/a"
declareGauge pendingReplace, "n/a"
declareGauge pendingRateLimit, "n/a" # Dropped due to rate limiting
declareGauge pendingNofunds, "n/a"   # Dropped due to out-of-funds


# Metrics for the queued pool

# core/tx_pool.go(103): queuedDiscardMeter = metrics.NewRegisteredMeter(..
declareGauge queuedDiscard, "n/a"
declareGauge queuedReplace, "n/a"
declareGauge queuedRateLimit, "n/a" # Dropped due to rate limiting
declareGauge queuedNofunds, "n/a"   # Dropped due to out-of-funds
declareGauge queuedEviction, "na"   # Dropped due to lifetime


# General tx metrics

# core/tx_pool.go(110): knownTxMeter = metrics.NewRegisteredMeter(..
declareGauge knownTransactions, "n/a"
declareGauge validTransactions, "n/a"
declareGauge invalidTransactions, "n/a"
declareGauge underpricedTransactions, "n/a"
declareGauge overflowedTransactions, "n/a"

# core/tx_pool.go(117): throttleTxMeter = metrics.NewRegisteredMeter(..
declareGauge throttleTransactions,
  "Rejected transactions due to too-many-changes between txpool reorgs"

# core/tx_pool.go(119): reorgDurationTimer = metrics.NewRegisteredTimer(..
declareGauge reorgDurationTimer, "Measures how long time a txpool reorg takes"

# core/tx_pool.go(122): dropBetweenReorgHistogram = metrics..
declareGauge dropBetweenReorgHistogram,
  "Number of expected drops between two reorg runs. It is expected that "&
    "this number is pretty low, since txpool reorgs happen very frequently"

# core/tx_pool.go(124): pendingGauge = metrics.NewRegisteredGauge(..
declareGauge pendingGauge, "n/a"
declareGauge queuedGauge, "n/a"
declareGauge localGauge, "n/a"
declareGauge slotsGauge, "n/a"

# core/tx_pool.go(129): reheapTimer = metrics.NewRegisteredTimer(..
declareGauge reheapTimer, "n/a"

# ----------------------

declareGauge unspecifiedError,
  "Some error occured but was not specified in any way. This counter should "&
    "stay zero."

# ------------------------------------------------------------------------------
# Global functions (publishing private setting sabove)
# ------------------------------------------------------------------------------

proc pendingDiscardMeter*(n = 1i64)       = pendingDiscard.inc(n)
proc pendingReplaceMeter*(n = 1i64)       = pendingReplace.inc(n)
proc pendingRateLimitMeter*(n = 1i64)     = pendingRateLimit.inc(n)
proc pendingNofundsMeter*(n = 1i64)       = pendingNofunds.inc(n)

proc queuedDiscardMeter*(n = 1i64)        = queuedDiscard.inc(n)
proc queuedReplaceMeter*(n = 1i64)        = queuedReplace.inc(n)
proc queuedRateLimitMeter*(n = 1i64)      = queuedRateLimit.inc(n)
proc queuedNofundsMeter*(n = 1i64)        = queuedNofunds.inc(n)
proc queuedEvictionMeter*(n = 1i64)       = queuedEviction.inc(n)

proc knownTxMeter*(n = 1i64)              = knownTransactions.inc(n)
proc invalidTxMeter*(n = 1i64)            = invalidTransactions.inc(n)
proc validTxMeter*(n = 1i64)              = validTransactions.inc(n)
proc underpricedTxMeter*(n = 1i64)        = underpricedTransactions.inc(n)
proc overflowedTxMeter*(n = 1i64)         = overflowedTransactions.inc(n)
proc throttleTxMeter*(n = 1i64)           = throttleTransactions.inc(n)

proc unspecifiedErrorMeter*(n = 1i64)     = unspecifiedError.inc(n)

proc reorgDurationTimerMeter*(n = 1i64)   = reorgDurationTimer.inc(n)
proc dropBetweenReorgHistogramMeter*(n = 1i64) =
                                            dropBetweenReorgHistogram.inc(n)
proc pendingGaugeMeter*(n = 1i64)         = pendingGauge.inc(n)
proc queuedGaugeMeter*(n = 1i64)          = queuedGauge.inc(n)
proc localGaugeMeter*(n = 1i64)           = localGauge.inc(n)
proc slotsGaugeMeter*(n = 1i64)           = slotsGauge.inc(n)

# ------------------------------------------------------------------------------
# End
# ------------------------------------------------------------------------------
