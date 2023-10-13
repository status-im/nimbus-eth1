import
  ../accounts_ledger as impl,
  ../base/base_desc

type
  AccountsLedgerRef* = ref object of LedgerRef
    ac*: impl.AccountsLedgerRef

  LedgerSavePoint* = ref object of LedgerSpRef
    sp*: impl.LedgerSavePoint

# End
