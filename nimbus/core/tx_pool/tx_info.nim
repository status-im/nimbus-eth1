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

    txInfoErrAncestorMissing = ##\
      ## Cannot forward current head as it is detached from the block chain
      "Lost header ancestor"

    txInfoErrChainHeadMissing = ##\
      ## Must not back move current head as it is detached from the block chain
      "Lost header position"

    txInfoErrForwardHeadMissing = ##\
      ## Cannot move forward current head to non-existing target position
      "Non-existing forward header"

    txInfoErrUnrootedCurChain = ##\
      ## Some orphan block found in current branch of the block chain
      "Orphan block in current branch"

    txInfoErrUnrootedNewChain = ##\
      ## Some orphan block found in new branch of the block chain
      "Orphan block in new branch"

    txInfoChainHeadUpdate = ##\
      ## Tx becomes obsolete as it is in a mined block, already
      "Tx obsoleted"

    # ---------- debugging error codes as used in verifier functions -----------

    # failed verifier codes

    txInfoVfyItemIdList            ## Corrupted ID queue/fifo structure
    txInfoVfyRejectsList           ## Corrupted waste basket structure
    txInfoVfyNonceChain            ## Non-consecutive nonces

    txInfoVfySenderRbTree          ## Corrupted sender list structure
    txInfoVfySenderLeafEmpty       ## Empty sender list leaf record
    txInfoVfySenderTotal           ## Wrong number of leaves
    txInfoVfySenderProfits         ## Profits calculation error

    txInfoVfyStatusTotal           ## Wrong number of leaves
    txInfoVfyStatusGasLimits       ## Wrong gas accu values
    txInfoVfyStatusSenderList      ## Corrupted status-sender sub-list
    txInfoVfyStatusNonceList       ## Corrupted status-nonce sub-list

    txInfoVfyStatusSenderTotal     ## Sender vs status table mismatch
    txInfoVfyStatusSenderGasLimits ## Wrong gas accu values

    txInfoVfyRankAddrMismatch      ## Different ranks in address set
    txInfoVfyReverseZombies        ## Zombie addresses in reverse lookup
    txInfoVfyRankReverseLookup     ## Sender missing in reverse lookup
    txInfoVfyRankReverseMismatch   ## Ranks differ with revers lookup
    txInfoVfyRankDuplicateAddr     ## Same address with different ranks
    txInfoVfyRankTotal             ## Wrong number of leaves (i.e. adresses)

# End
