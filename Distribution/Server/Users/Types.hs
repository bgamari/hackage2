{-# LANGUAGE DeriveDataTypeable, GeneralizedNewtypeDeriving, TemplateHaskell #-}
module Distribution.Server.Users.Types (
    module Distribution.Server.Users.Types,
    module Distribution.Server.Auth.Types
  ) where

import Distribution.Server.Auth.Types

import Distribution.Text
         ( Text(..) )
import qualified Distribution.Server.Util.Parse as Parse
import qualified Distribution.Compat.ReadP as Parse
import qualified Text.PrettyPrint          as Disp
import qualified Data.Char as Char

import Data.Serialize (Serialize)
import Control.Applicative ((<$>))

import Data.SafeCopy (base, deriveSafeCopy)
import Data.Typeable (Typeable)

newtype UserId = UserId Int
  deriving (Eq, Ord, Show, Serialize, Typeable)

newtype UserName  = UserName String
  deriving (Eq, Ord, Show, Serialize, Typeable)

data UserInfo = UserInfo {
    userName   :: UserName,
    userStatus :: UserStatus
  } deriving (Show, Typeable)

data UserStatus = Deleted
                | Historical
                | Active !AccountEnabled UserAuth
    deriving (Show, Typeable)
data AccountEnabled = Enabled | Disabled deriving (Show, Enum, Eq, Typeable)

data UserAuth = UserAuth PasswdHash AuthType deriving (Show, Eq, Typeable)

instance Text UserId where
    disp (UserId uid) = Disp.int uid
    parse = UserId <$> Parse.int

instance Text UserName where
    disp (UserName name) = Disp.text name
    parse = UserName <$> Parse.munch1 Char.isAlphaNum

$(deriveSafeCopy 0 'base ''UserId)
$(deriveSafeCopy 0 'base ''UserName)
$(deriveSafeCopy 0 'base ''AccountEnabled)
$(deriveSafeCopy 0 'base ''UserAuth)
$(deriveSafeCopy 0 'base ''UserStatus)
$(deriveSafeCopy 0 'base ''UserInfo)
