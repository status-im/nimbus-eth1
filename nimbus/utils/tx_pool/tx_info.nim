# Nimbus
# Copyright (c) 2018 Status Research & Development GmbH
# Licensed under either of
#  * Apache License, version 2.0, ([LICENSE-APACHE](LICENSE-APACHE) or
#    http://www.apache.org/licenses/LICENSE-2.0)
#  * MIT license ([LICENSE-MIT](LICENSE-MIT) or
#    http://opensource.org/licenses/MIT)
# at your option. This file may not be copied, modified, or distributed except
# according to those terms.

## Transaction Pool Info Symbols & Error Codes
## ===========================================

type
  TxInfo* = enum ##\
    ## Return codes
    txOk = 0

    txTabsErrAlreadyKnown
    txTabsErrInvalidSender

  TxVfyError* = enum ##\
    ## Error codes (as used in verification function.)
    txVfyOk = 0

    # failed verifier codes
    txVfyItemIdList         ## Corrupted ID queue/fifo structure
    txVfyItemIdTotal        ## Wrong number of leaves

    txVfySenderRbTree       ## Corrupted sender list structure
    txVfySenderLeafEmpty    ## Empty sender list leaf record
    txVfySenderLeafQueue    ## Corrupted sender leaf queue
    txVfySenderTotal        ## Wrong number of leaves

    txVfyNonceList          ## Corrupted nonce list structure
    txVfyNonceLeafEmpty     ## Empty nonce list leaf record
    txVfyNonceLeafQueue     ## Corrupted nonce leaf queue
    txVfyNonceTotal         ## Wrong number of leaves

    txVfyGasTipList         ## Corrupted gas price list structure
    txVfyGasTipLeafEmpty    ## Empty gas price list leaf record
    txVfyGasTipLeafQueue    ## Corrupted gas price leaf queue
    txVfyGasTipTotal        ## Wrong number of leaves

    txVfyTipCapList         ## Corrupted gas price list structure
    txVfyTipCapLeafEmpty    ## Empty gas price list leaf record
    txVfyTipCapLeafQueue    ## Corrupted gas price leaf queue
    txVfyTipCapTotal        ## Wrong number of leaves

    # codes provided for other modules
    txVfyJobsQueue          ## Corrupted jobs queue/fifo structure

# End
