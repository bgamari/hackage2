module Distribution.Server.Feature where

import Distribution.Server.Import (RestoreBackup, BackupEntry)
import Distribution.Server.Resource

-- This module defines a plugin interface for hackage features.
--
-- We compose the overall hackage server featureset from a bunch of these
-- features. The intention is to make the hackage server reasonably modular
-- by allowing distinct features to be designed independently.

data HackageFeature = HackageFeature {
    featureName    :: String,
    locations      :: [(BranchPath, ServerResponse)],
--  resources      :: [Resource],
    dumpBackup     :: IO [BackupEntry],
    restoreBackup  :: Maybe RestoreBackup
}

