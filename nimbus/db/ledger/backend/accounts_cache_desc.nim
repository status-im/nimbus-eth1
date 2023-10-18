import
  ../accounts_cache as impl,
  ../base/base_desc

type
  AccountsCache* = ref object of LedgerRef
    ac*: impl.AccountsCache

  SavePoint* = ref object of LedgerSpRef
    sp*: impl.SavePoint

# End
