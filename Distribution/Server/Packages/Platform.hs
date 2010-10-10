{-# LANGUAGE DeriveDataTypeable, TypeFamilies, TemplateHaskell,
             FlexibleInstances, FlexibleContexts, MultiParamTypeClasses,
             TypeOperators, TypeSynonymInstances, GeneralizedNewtypeDeriving #-}

module Distribution.Server.Packages.Platform where

import Data.Map (Map)
import qualified Data.Map as Map
import Data.Set (Set)
import qualified Data.Set as Set
import Data.Typeable

import Distribution.Server.Instances ()
import Distribution.Package
import Distribution.Version

import Control.Monad.Reader (ask, asks)
import Control.Monad.State (put, modify)
import Happstack.State hiding (Version)
import qualified Happstack.State as Happstack (Version)

newtype PlatformPackages = PlatformPackages {
    blessedPackages :: Map PackageName (Set Version)
} deriving (Show, Typeable)
emptyPlatformPackages :: PlatformPackages
emptyPlatformPackages = PlatformPackages Map.empty

getPlatformPackages :: Query PlatformPackages PlatformPackages
getPlatformPackages = ask

getPlatformPackage :: PackageName -> Query PlatformPackages (Set Version)
getPlatformPackage pkgname = asks (Map.findWithDefault Set.empty pkgname . blessedPackages)

setPlatformPackage :: PackageName -> Set Version -> Update PlatformPackages ()
setPlatformPackage pkgname versions = modify $ \p -> case Set.null versions of
    True  -> p { blessedPackages = Map.delete pkgname $ blessedPackages p }
    False -> p { blessedPackages = Map.insert pkgname versions $ blessedPackages p }

replacePlatformPackages :: PlatformPackages -> Update PlatformPackages ()
replacePlatformPackages = put

instance Happstack.Version PlatformPackages
$(deriveSerialize ''PlatformPackages)

instance Component PlatformPackages where
    type Dependencies PlatformPackages = End
    initialValue = emptyPlatformPackages

$(mkMethods ''PlatformPackages ['getPlatformPackages
                               ,'getPlatformPackage
                               ,'setPlatformPackage
                               ,'replacePlatformPackages
                               ])

