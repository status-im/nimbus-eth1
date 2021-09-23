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
declareGauge pendingDiscardMeter, "n/a"
declareGauge pendingReplaceMeter, "n/a"
declareGauge pendingRateLimitMeter, "n/a" # Dropped due to rate limiting
declareGauge pendingNofundsMeter, "n/a"   # Dropped due to out-of-funds


# Metrics for the queued pool

# core/tx_pool.go(103): queuedDiscardMeter = metrics.NewRegisteredMeter(..
declareGauge queuedDiscardMeter, "n/a"
declareGauge queuedReplaceMeter, "n/a"
declareGauge queuedRateLimitMeter, "n/a" # Dropped due to rate limiting
declareGauge queuedNofundsMeter, "n/a"   # Dropped due to out-of-funds
declareGauge queuedEvictionMeter, "na"   # Dropped due to lifetime


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

# ------------------------------------------------------------------------------
# Global functions (publishing private setting sabove)
# ------------------------------------------------------------------------------

proc pendingDiscardMeterMark*(n = 1i64)       = pendingDiscardMeter.inc(n)
proc pendingReplaceMeterMark*(n = 1i64)       = pendingReplaceMeter.inc(n)
proc pendingRateLimitMeterMark*(n = 1i64)     = pendingRateLimitMeter.inc(n)
proc pendingNofundsMeterMark*(n = 1i64)       = pendingNofundsMeter.inc(n)

proc queuedDiscardMeterMark*(n = 1i64)        = queuedDiscardMeter.inc(n)
proc queuedReplaceMeterMark*(n = 1i64)        = queuedReplaceMeter.inc(n)
proc queuedRateLimitMeterMark*(n = 1i64)      = queuedRateLimitMeter.inc(n)
proc queuedNofundsMeterMark*(n = 1i64)        = queuedNofundsMeter.inc(n)
proc queuedEvictionMeterMark*(n = 1i64)       = queuedEvictionMeter.inc(n)

proc knownTxMeterMark*(n = 1i64)              = knownTransactions.inc(n)
proc invalidTxMeterMark*(n = 1i64)            = invalidTransactions.inc(n)
proc validTxMeterMark*(n = 1i64)              = validTransactions.inc(n)
proc underpricedTxMeterMark*(n = 1i64)        = underpricedTransactions.inc(n)
proc overflowedTxMeterMark*(n = 1i64)         = overflowedTransactions.inc(n)
proc throttleTxMeterMark*(n = 1i64)           = throttleTransactions.inc(n)

proc reorgDurationTimerMark*(n = 1i64)        = reorgDurationTimer.inc(n)
proc dropBetweenReorgHistogramMark*(n = 1i64) = dropBetweenReorgHistogram.inc(n)
proc pendingGaugeMark*(n = 1i64)              = pendingGauge.inc(n)
proc queuedGaugeMark*(n = 1i64)               = queuedGauge.inc(n)
proc localGaugeMark*(n = 1i64)                = localGauge.inc(n)
proc slotsGaugeMark*(n = 1i64)                = slotsGauge.inc(n)

# ------------------------------------------------------------------------------
# End
# ------------------------------------------------------------------------------
