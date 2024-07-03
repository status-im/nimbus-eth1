Core database
=============

Layout of `CoreDb` descriptor objects
-------------------------------------

### Objects dependence:

        CoreDbRef                           -- Base descriptor
         | | |
         | | +--- CoreDbCtxRef              -- Context descriptor
         | |       | | | |
         | |       | | | +--- CoreDbKvtRef  -- Key-value table
         | |       | | |
         | |       | | +----- CoreDbMptRef  -- Generic MPT
         | |       | |
         | |       | +------- CoreDbAccRef  -- Accounts database
         | |       |
		 | |       +--------- CoreDbTxRef   -- Transaction handle
         | |
         | +----- CoreDbCtxRef
         |         : : : :
         |
         +------- CoreDbCtxRef
                   : : : :

