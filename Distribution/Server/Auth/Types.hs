{-# LANGUAGE DeriveDataTypeable, GeneralizedNewtypeDeriving, TemplateHaskell #-}
module Distribution.Server.Auth.Types where

import Data.Binary (Binary)
import Data.SafeCopy (base, deriveSafeCopy)
import Data.Typeable (Typeable)

-- | A plain, unhashed password. Careful what you do with them.
--
newtype PasswdPlain = PasswdPlain String
  deriving Eq

-- | A password hash. It actually contains the hash of the username, passowrd
-- and realm.
--
-- Hashed passwords are stored in the format
-- @md5 (username ++ ":" ++ realm ++ ":" ++ password)@. This format enables
-- us to use either the basic or digest HTTP authentication methods.
--
newtype PasswdHash = PasswdHash String
  deriving (Eq, Ord, Show, Binary, Typeable)

newtype RealmName = RealmName String
  deriving (Show, Eq)

$(deriveSafeCopy 0 'base ''PasswdHash)
