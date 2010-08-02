module Distribution.Server.Cache (
    Cache(..),
    newCache,
    newCacheable,
    getCache,
    putCache,
    modifyCache,
    respondCache
  ) where

import qualified Distribution.Server.Util.AsyncVar as AsyncVar
import Distribution.Server.Util.AsyncVar (AsyncVar)

import Happstack.Server

import Control.Monad.Trans (MonadIO(liftIO))
import Control.Parallel.Strategies

-------------------------- this should replace Cache eventually
-- though it's an extremely loose wrapper around AsyncVar, so why not use that directly?
newtype Cache a = Cache { cacheState :: AsyncVar a }

newCache :: a -> (a -> b) -> IO (Cache a)
newCache state forceFunc = Cache `fmap` AsyncVar.new (\a -> forceFunc a `seq` ()) state

newCacheable :: NFData a => a -> IO (Cache a)
newCacheable emptyValue = newCache emptyValue rnf

getCache :: MonadIO m => Cache a -> m a
getCache (Cache avar) = liftIO $ AsyncVar.read avar

putCache :: MonadIO m => Cache a -> a -> m ()
putCache (Cache avar) state = liftIO $ AsyncVar.write avar state

modifyCache :: MonadIO m => Cache a -> (a -> a) -> m ()
modifyCache (Cache avar) func = liftIO $ AsyncVar.modify avar func

-----------------------------------------------------------------------
-- usually b = DynamicPath. This saves on code nodes (elsewhere) and imports (here)
respondCache :: ToMessage r => Cache a -> (a -> r) -> b -> ServerPart Response
respondCache cache func _ = return . toResponse . func =<< getCache cache

