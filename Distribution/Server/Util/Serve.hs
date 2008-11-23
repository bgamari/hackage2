-----------------------------------------------------------------------------
-- |
-- Module      :  Distribution.Server.Util.Serve
-- Copyright   :  (c) 2008 David Himmelstrup
-- License     :  BSD-like
--
-- Maintainer  :  duncan@haskell.org
-- Stability   :  provisional
-- Portability :  portable
--
--
-----------------------------------------------------------------------------
module Distribution.Server.Util.Serve where

import HAppS.Server
import HAppS.Server.HTTP.FileServe (mimeTypes)
import Distribution.Server.Util.Tar as Tar

import Data.Maybe (listToMaybe)
import qualified Data.Map as Map
import qualified Codec.Compression.GZip as GZip
import System.FilePath
--import Data.Time.Clock.POSIX
import Control.Monad.Trans (liftIO)

serveTarball _indices _offset rq _tarball | rqMethod rq /= GET = noHandle
serveTarball indices offset rq tarball
    = do let entries = Tar.read (GZip.decompress tarball)
             path    = joinPath (rqPaths rq)
             mime x  = Map.findWithDefault "text/plain" (drop 1 (takeExtension x)) mimeTypes
             fileMap = Tar.foldEntries (\entry -> Map.insert (fromTarPath (filePath entry)) entry) Map.empty error entries
         case listToMaybe [ (val,key) | key <- path:indices, Just val <- [Map.lookup (offset </> key) fileMap]] of
           Nothing -> noHandle
           Just (entry,key) -> ok $ Response
                                { rsCode = 200
                                , rsHeaders = mkHeaders $ [("Content-Length", show (fileSize entry))
                                                          ,("Content-Type", mime key)
                                                          ]
                                , rsFlags = nullRsFlags { rsfContentLength = False }
                                , rsBody  = fileContent entry
                                , rsValidator = Nothing
                                }{-
             findPath [] _ = noHandle
             findPath (key:ks) Done = findPath ks entries
             findPath _keys (Fail str) = internalServerError $ toResponse $ "Invalid tarball: " ++ str
             findPath (key:ks) (Next entry entries)
                 | fromTarPath (filePath entry) == offset </> key && fileSize entry > 0
                        = ok $ Response
                                { rsCode = 200
                                , rsHeaders = mkHeaders $ [("Content-Length", show (fileSize entry))
                                                          ,("Content-Type", mime key)
                                                          ]
                                , rsFlags = nullRsFlags { rsfContentLength = False }
                                , rsBody  = fileContent entry
                                , rsValidator = Nothing
                                }
                 | otherwise = do liftIO $ putStrLn $ "Not it: " ++ show (fromTarPath (filePath entry), offset </> key)
                                  findPath (key:ks) entries
         findPath (path:indices) entries
-}
