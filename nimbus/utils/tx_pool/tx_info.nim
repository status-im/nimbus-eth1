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
  TxPoolError* = enum
    txPoolErrNone = ##\
      ## Default/reset value
      (0, "no error")

    txPoolErrUnspecified = ##\
      ## Some unspecified error occured
      "generic error"

    txPoolErrAlreadyKnown = ##\
      ## The transactions is already contained within the pool
      "already known"

    txPoolErrInvalidSender = ##\
      ## The transaction contains an invalid signature.
      "invalid sender"

    txPoolErrUnderpriced = ##\
      ## A transaction's gas price is below the minimum configured for the
      ## transaction pool.
      "transaction underpriced"

    txPoolErrTxPoolOverflow = ##\
      ## The transaction pool is full and can't accpet another remote
      ## transaction.
      "txpool is full"

    txPoolErrReplaceUnderpriced = ##\
      ## A transaction is attempted to be replaced with a different one
      ## without the required price bump.
      "replacement transaction underpriced"

    txPoolErrGasLimit = ##\
      ## A transaction's requested gas limit exceeds the maximum allowance
      ## of the current block.
      "exceeds block gas limit"

    txPoolErrNegativeValue = ##\
      ## A sanity error to ensure no one is able to specify a transaction
      ## with a negative value.
      "negative value"

    txPoolErrOversizedData = ##\
      ## The input data of a transaction is greater than some meaningful
      ## limit a user might use. This is not a consensus error making the
      ## transaction invalid, rather a DOS protection.
      "oversized data"

  TxInfo* = enum ##\
    ## Return codes
    txOk = 0

    txTabsErrAlreadyKnown
    txTabsErrInvalidSender

  TxVfyError* = enum ##\
    ## Error codes (as used in verification function.)
    txVfyOk = 0

    # failed verifier codes
    txVfyLeafQueue          ## Corrupted leaf item queue

    txVfyGasTipList         ## Corrupted gas price list structure
    txVfyGasTipLeafEmpty    ## Empty gas price list leaf record
    txVfyGasTipLeafQueue    ## Corrupted gas price leaf queue
    txVfyGasTipTotal        ## Wrong number of leaves

    txVfyItemIdList         ## Corrupted ID queue/fifo structure
    txVfyItemIdTotal        ## Wrong number of leaves

    txVfyNonceList          ## Corrupted nonce list structure
    txVfyNonceLeafEmpty     ## Empty nonce list leaf record
    txVfyNonceLeafQueue     ## Corrupted nonce leaf queue
    txVfyNonceTotal         ## Wrong number of leaves

    txVfySenderRbTree       ## Corrupted sender list structure
    txVfySenderLeafEmpty    ## Empty sender list leaf record
    txVfySenderLeafQueue    ## Corrupted sender leaf queue
    txVfySenderTotal        ## Wrong number of leaves

    txVfyStatusRbTree       ## Corrupted status list structure
    txVfyStatusLeafEmpty    ## Empty status list leaf record
    txVfyStatusLeafQueue    ## Corrupted status leaf queue
    txVfyStatusTotal        ## Wrong number of leaves

    txVfyStatusSenderTotal  ## Sender vs status table mismatch

    txVfyTipCapList         ## Corrupted gas price list structure
    txVfyTipCapLeafEmpty    ## Empty gas price list leaf record
    txVfyTipCapLeafQueue    ## Corrupted gas price leaf queue
    txVfyTipCapTotal        ## Wrong number of leaves

    # codes provided for other modules
    txVfyJobQueue           ## Corrupted jobs queue/fifo structure

# End
