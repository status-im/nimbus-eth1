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

{.push raises: [].}

type TxInfo* = enum
  txInfoOk = (0, "no error")
  ##\
  ## The transaction was disposed after packing into block
  txInfoPackedBlockIncluded = "not needed anymore"
  ##\
  ## Tx superseded by another one with same <sender,nonce> index
  txInfoSenderNonceSuperseded = "Sender/nonce index superseded"
  ##\
  ## Non consecutive nonces detected after moving back the block chain
  ## head. This should not happen and indicates an inconsistency between
  ## cached transactions and the ones on the block chain.
  txInfoErrNonceGap = "nonce gap"
  ##\
  ## Implied disposal, applies to transactions with higher nonces after
  ## a `txInfoErrNonceGap` error.
  txInfoErrImpliedNonceGap = "implied nonce gap"
  ##\
  ## Unspecified disposal reason (fallback value)
  txInfoExplicitDisposal = "on-demand disposal"
  ##\
  ## Implied disposal, typically implied by greater nonces (fallback value)
  txInfoImpliedDisposal = "implied disposal"
  ##\
  ## Tx chainId does not match with network chainId
  txInfoChainIdMismatch = "chainId mismatch"
  ##\
  ## Some unspecified error occured
  # ------ Miscellaneous errors ----------------------------------------------
  txInfoErrUnspecified = "generic error"
  ##\
  ## Cannot dispose non-existing item
  txInfoErrVoidDisposal = "void disposal"
  ##\
  ## The transactions is already contained within the pool
  txInfoErrAlreadyKnown = "already known"
  ##\
  ## <sender,nonce> index for transaction exists, already.
  txInfoErrSenderNonceIndex = "Sender/nonce index error"
  ##\
  ## The transaction pool is full and can't accpet another remote
  ## transaction.
  txInfoErrTxPoolOverflow = "txpool is full"
  ##\
  ## The input data of a transaction is greater than some meaningful
  ## limit a user might use. This is not a consensus error making the
  ## transaction invalid, rather a DOS protection.

  # ------ Transaction format/parsing problems -------------------------------
  txInfoErrOversizedData = "Oversized tx data"
  ##\
  ## A sanity error to ensure no one is able to specify a transaction
  ## with a negative value.
  txInfoErrNegativeValue = "Negative value in tx"
  ##\
  ## Transaction type does not supported EIP-1559 protected signature
  txInfoErrUnexpectedProtection = "Unsupported EIP-1559 signature protection"
  ##\
  ## Transaction type not valid in this context
  txInfoErrInvalidTxType = "Unsupported tx type"
  ##\
  ## Transaction type not supported
  txInfoErrTxTypeNotSupported = "Unsupported transaction type"
  ##\
  ## Typed transaction, missing data
  txInfoErrEmptyTypedTx = "Empty typed transaction bytes"
  ##\
  ## Running basic validator failed on current transaction
  txInfoErrBasicValidatorFailed = "Tx rejected by basic validator"
  ##\
  ## Invalid EIP-4844 kzg validation on blob wrapper
  txInfoErrInvalidBlob = "Invalid EIP-4844 blob validation"
  ##\
  ## The transaction contains an invalid signature.

  # ------ Signature problems ------------------------------------------------
  txInfoErrInvalidSender = "invalid sender"
  ##\
  ## invalid transaction v, r, s values
  txInfoErrInvalidSig = "Invalid transaction signature"
  ##\
  ## A transaction's gas price is below the minimum configured for the
  ## transaction pool.

  # ------ Gas fee and selection problems ------------------------------------
  txInfoErrUnderpriced = "Tx underpriced"
  ##\
  ## A transaction is attempted to be replaced with a different one
  ## without the required price bump.
  txInfoErrReplaceUnderpriced = "Replacement tx underpriced"
  ##\
  ## A transaction's requested gas limit exceeds the maximum allowance
  ## of the current block.
  txInfoErrGasLimit = "Tx exceeds block gasLimit"
  ##\
  ## Gase fee cap less than base fee
  txInfoErrGasFeeCapTooLow = "Tx has feeCap < baseFee"
  ##\
  ## A transaction has been on the system for too long so it was removed.

  # ------- operational events related to transactions -----------------------
  txInfoErrTxExpired = "Tx expired"
  ##\
  ## Implied disposal for greater nonces for the same sender when the base
  ## tx was removed.
  txInfoErrTxExpiredImplied = "Tx expired implied"
  ##\
  ## A transaction was item was created and stored in the disposal bin
  ## to be recycled and processed later.
  txInfoTxStashed = "Tx stashed"
  ##\
  ## The sender account of a transaction was expected non-local.
  txInfoTxErrorRemoteExpected = "Tx non-local expected"
  ##\
  ## The sender account of a transaction was expected local.
  txInfoTxErrorLocalExpected = "Tx local expected"
  ##\
  ## Cannot forward current head as it is detached from the block chain

  # ------- update/move block chain head -------------------------------------
  txInfoErrAncestorMissing = "Lost header ancestor"
  ##\
  ## Must not back move current head as it is detached from the block chain
  txInfoErrChainHeadMissing = "Lost header position"
  ##\
  ## Cannot move forward current head to non-existing target position
  txInfoErrForwardHeadMissing = "Non-existing forward header"
  ##\
  ## Some orphan block found in current branch of the block chain
  txInfoErrUnrootedCurChain = "Orphan block in current branch"
  ##\
  ## Some orphan block found in new branch of the block chain
  txInfoErrUnrootedNewChain = "Orphan block in new branch"
  ##\
  ## Tx becomes obsolete as it is in a mined block, already
  txInfoChainHeadUpdate = "Tx obsoleted"

  # ---------- debugging error codes as used in verifier functions -----------

  # failed verifier codes
  txInfoVfyLeafQueue ## Corrupted leaf item queue
  txInfoVfyItemIdList ## Corrupted ID queue/fifo structure
  txInfoVfyRejectsList ## Corrupted waste basket structure
  txInfoVfyNonceChain ## Non-consecutive nonces
  txInfoVfySenderRbTree ## Corrupted sender list structure
  txInfoVfySenderLeafEmpty ## Empty sender list leaf record
  txInfoVfySenderLeafQueue ## Corrupted sender leaf queue
  txInfoVfySenderTotal ## Wrong number of leaves
  txInfoVfySenderGasLimits ## Wrong gas accu values
  txInfoVfySenderProfits ## Profits calculation error
  txInfoVfyStatusRbTree ## Corrupted status list structure
  txInfoVfyStatusTotal ## Wrong number of leaves
  txInfoVfyStatusGasLimits ## Wrong gas accu values
  txInfoVfyStatusSenderList ## Corrupted status-sender sub-list
  txInfoVfyStatusNonceList ## Corrupted status-nonce sub-list
  txInfoVfyStatusSenderTotal ## Sender vs status table mismatch
  txInfoVfyStatusSenderGasLimits ## Wrong gas accu values
  txInfoVfyRankAddrMismatch ## Different ranks in address set
  txInfoVfyReverseZombies ## Zombie addresses in reverse lookup
  txInfoVfyRankReverseLookup ## Sender missing in reverse lookup
  txInfoVfyRankReverseMismatch ## Ranks differ with revers lookup
  txInfoVfyRankDuplicateAddr ## Same address with different ranks
  txInfoVfyRankTotal ## Wrong number of leaves (i.e. adresses)

  # codes provided for other modules
  txInfoVfyJobQueue ## Corrupted jobs queue/fifo structure
  txInfoVfyJobEvent ## Event table sync error

# End
