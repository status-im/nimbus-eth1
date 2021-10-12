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
  TxInfo* = enum
    txInfoOk =
      (0, "no error")

    txInfoStagedBlockIncluded = ##\
      ## The transaction was disposed after packing into block
      "not needed anymore"

    txInfoSenderNonceSuperseded = ##\
      ## Tx superseded by another one with same <sender,nonce> index
      "Sender/nonce index superseded"

    # ------ Miscellaneous errors ------------------------------------

    txInfoErrUnspecified = ##\
      ## Some unspecified error occured
      "generic error"

    txInfoErrVoidDisposal = ##\
      ## Cannot dispose non-existing item
      "void disposal"

    txInfoErrAlreadyKnown = ##\
      ## The transactions is already contained within the pool
      "already known"

    txInfoErrSenderNonceIndex = ##\
      ## <sender,nonce> index for transaction exists, already.
      "Sender/nonce index error"

    txInfoErrTxPoolOverflow = ##\
      ## The transaction pool is full and can't accpet another remote
      ## transaction.
      "txpool is full"

    # ------ Transaction format/parsing problems ---------------------

    txInfoErrOversizedData = ##\
      ## The input data of a transaction is greater than some meaningful
      ## limit a user might use. This is not a consensus error making the
      ## transaction invalid, rather a DOS protection.
      "Oversized tx data"

    txInfoErrNegativeValue = ##\
      ## A sanity error to ensure no one is able to specify a transaction
      ## with a negative value.
      "Negative value in tx"

    txInfoErrUnexpectedProtection = ##\
      ## Transaction type does not supported EIP-1559 protected signature
      "Unsupported EIP-1559 signature protection"

    txInfoErrInvalidTxType = ##\
      ## Transaction type not valid in this context
      "Unsupported tx type"

    txInfoErrTxTypeNotSupported = ##\
      ## Transaction type not supported
      "Unsupported transaction type"

    txInfoErrEmptyTypedTx = ##\
      ## Typed transaction, missing data
      "Empty typed transaction bytes"

    txInfoErrBasicValidatorFailed = ##\
      ## Running basic validator failed on current transaction
      "Tx rejected by basic validator"

    # ------ Signature problems ---------------------

    txInfoErrInvalidSender = ##\
      ## The transaction contains an invalid signature.
      "invalid sender"

    txInfoErrInvalidSig = ##\
      ## invalid transaction v, r, s values
      "Invalid transaction signature"

    # ------ Gas fee and selection problems ---------------------

    txInfoErrUnderpriced = ##\
      ## A transaction's gas price is below the minimum configured for the
      ## transaction pool.
      "Tx underpriced"

    txInfoErrReplaceUnderpriced = ##\
      ## A transaction is attempted to be replaced with a different one
      ## without the required price bump.
      "Replacement tx underpriced"

    txInfoErrGasLimit = ##\
      ## A transaction's requested gas limit exceeds the maximum allowance
      ## of the current block.
      "Tx exceeds block gasLimit"

    txInfoErrGasFeeCapTooLow = ##\
      ## Gase fee cap less than base fee
      "Tx has feeCap < baseFee"

    # ------ operational events related to transactions ---------------------

    txInfoErrTxExpired = ##\
      ## A transaction has been on the system for too long so it was removed.
      "Tx expired"

    # ------- debugging error codes as used in verification function -------

    # failed verifier codes
    txInfoVfyLeafQueue          ## Corrupted leaf item queue

    txInfoVfyGasTipList         ## Corrupted gas price list structure
    txInfoVfyGasTipLeafEmpty    ## Empty gas price list leaf record
    txInfoVfyGasTipLeafQueue    ## Corrupted gas price leaf queue
    txInfoVfyGasTipTotal        ## Wrong number of leaves

    txInfoVfyItemIdList         ## Corrupted ID queue/fifo structure
    txInfoVfyItemIdTotal        ## Wrong number of leaves

    txInfoVfyNonceList          ## Corrupted nonce list structure
    txInfoVfyNonceLeafEmpty     ## Empty nonce list leaf record
    txInfoVfyNonceLeafQueue     ## Corrupted nonce leaf queue
    txInfoVfyNonceTotal         ## Wrong number of leaves

    txInfoVfySenderRbTree       ## Corrupted sender list structure
    txInfoVfySenderLeafEmpty    ## Empty sender list leaf record
    txInfoVfySenderLeafQueue    ## Corrupted sender leaf queue
    txInfoVfySenderTotal        ## Wrong number of leaves

    txInfoVfyStatusRbTree       ## Corrupted status list structure
    txInfoVfyStatusLeafEmpty    ## Empty status list leaf record
    txInfoVfyStatusLeafQueue    ## Corrupted status leaf queue
    txInfoVfyStatusTotal        ## Wrong number of leaves

    txInfoVfyStatusSenderTotal  ## Sender vs status table mismatch

    txInfoVfyTipCapList         ## Corrupted gas price list structure
    txInfoVfyTipCapLeafEmpty    ## Empty gas price list leaf record
    txInfoVfyTipCapLeafQueue    ## Corrupted gas price leaf queue
    txInfoVfyTipCapTotal        ## Wrong number of leaves

    # codes provided for other modules
    txInfoVfyJobQueue           ## Corrupted jobs queue/fifo structure
    txInfoVfyJobEvent           ## Event table sync error

# End
