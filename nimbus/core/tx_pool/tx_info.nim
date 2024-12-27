# Nimbus
# Copyright (c) 2018-2024 Status Research & Development GmbH
# Licensed under either of
#  * Apache License, version 2.0, ([LICENSE-APACHE](LICENSE-APACHE) or
#    http://www.apache.org/licenses/LICENSE-2.0)
#  * MIT license ([LICENSE-MIT](LICENSE-MIT) or
#    http://opensource.org/licenses/MIT)
# at your option. This file may not be copied, modified, or distributed except
# according to those terms.

## Transaction Pool Info Symbols & Error Codes
## ===========================================

{.push raises: [].}

type
  TxInfo* = enum
    txInfoOk =
      (0, "no error")

    txInfoSenderNonceSuperseded = ##\
      ## Tx superseded by another one with same <sender,nonce> index
      "Sender/nonce index superseded"

    txInfoErrNonceGap = ##\
      ## Non consecutive nonces detected after moving back the block chain
      ## head. This should not happen and indicates an inconsistency between
      ## cached transactions and the ones on the block chain.
      "nonce gap"

    txInfoErrImpliedNonceGap = ##\
      ## Implied disposal, applies to transactions with higher nonces after
      ## a `txInfoErrNonceGap` error.
      "implied nonce gap"

    txInfoExplicitDisposal = ##\
      ## Unspecified disposal reason (fallback value)
      "on-demand disposal"

    txInfoImpliedDisposal = ##\
      ## Implied disposal, typically implied by greater nonces (fallback value)
      "implied disposal"

    txInfoChainIdMismatch = ##\
      ## Tx chainId does not match with network chainId
      "chainId mismatch"
    # ------ Miscellaneous errors ----------------------------------------------

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

    # ------ Transaction format/parsing problems -------------------------------

    txInfoErrBasicValidatorFailed = ##\
      ## Running basic validator failed on current transaction
      "Tx rejected by basic validator"

    txInfoErrInvalidBlob = ##\
      ## Invalid EIP-4844 kzg validation on blob wrapper
      "Invalid EIP-4844 blob validation"

    # ------ Signature problems ------------------------------------------------

    txInfoErrInvalidSender = ##\
      ## The transaction contains an invalid signature.
      "invalid sender"

    # ------ Gas fee and selection problems ------------------------------------


    txInfoErrReplaceUnderpriced = ##\
      ## A transaction is attempted to be replaced with a different one
      ## without the required price bump.
      "Replacement tx underpriced"

    # ------- operational events related to transactions -----------------------

    txInfoErrTxExpired = ##\
      ## A transaction has been on the system for too long so it was removed.
      "Tx expired"

    txInfoErrTxExpiredImplied = ##\
     ## Implied disposal for greater nonces for the same sender when the base
     ## tx was removed.
     "Tx expired implied"

    # ------- update/move block chain head -------------------------------------

    txInfoErrForwardHeadMissing = ##\
      ## Cannot move forward current head to non-existing target position
      "Non-existing forward header"

    txInfoChainHeadUpdate = ##\
      ## Tx becomes obsolete as it is in a mined block, already
      "Tx obsoleted"

# End
