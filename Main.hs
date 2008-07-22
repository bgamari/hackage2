module Main (main) where

import Distribution.Package (PackageIdentifier(..))
import Distribution.Text    (display, simpleParse)
import HAppS.Server
import HAppS.State

import Distribution.Server.PackagesState
import Distribution.Server.Caches
import qualified Distribution.PackageDescription as PD
import qualified Distribution.Simple.PackageIndex as PackageIndex
import qualified Distribution.Server.IndexUtils as PackageIndex (read)
import Distribution.Server.Types (PkgInfo(..))

import qualified Distribution.Server.Pages.Index   as Pages (packageIndex)
import qualified Distribution.Server.Pages.Package as Pages

import System.Environment
import Control.Exception
import Data.Maybe
import Control.Monad
import Control.Monad.Trans

import Unpack (unpackPackage)
import qualified Distribution.Server.BlobStorage as Blob

import qualified Data.ByteString.Char8 as BS
import qualified Data.ByteString.Lazy.Char8 as BS.Lazy

hackageEntryPoint :: Proxy PackagesState
hackageEntryPoint = Proxy

main :: IO ()
main = bracket (startSystemState hackageEntryPoint) shutdownSystem $ \_ctl ->
       do cacheThread
          args <- getArgs -- FIXME: use GetOpt
          forM_ args $ \pkgFile ->
              do pkgIndex <- either fail return
                           . PackageIndex.read PkgInfo
                         =<< BS.Lazy.readFile pkgFile
                 update $ BulkImport (PackageIndex.allPackages pkgIndex)
          simpleHTTP nullConf { port = 5000 } impl


handlePackageById :: PackageIdentifier -> [ServerPart Response]
handlePackageById pkgid =
  [ anyRequest $ do mbPkgInfo <- query $ LookupPackageId pkgid
                    ok $ toResponse $
                           "Package " ++ display pkgid ++ " addressed.\n"
                           ++ case mbPkgInfo of
                                Nothing -> "No such package"
	                        Just pkg -> PD.author pkg_desc
                                    where pkg_desc = PD.packageDescription (pkgDesc pkg)
  ]

downloadPackageById pkgid =
    [ anyRequest $ do mbPkgInfo <- query $ LookupPackageId pkgid
                      blobId <- undefined
                      store <- liftIO $ Blob.open "packages"
                      file <- liftIO $ Blob.fetch store blobId
                      ok $ toResponse $ Tarball file
    ]

newtype Tarball = Tarball BS.Lazy.ByteString

instance ToMessage Tarball where
    toContentType _ = BS.pack "application/gzip"
    toMessage (Tarball bs) = bs

instance FromReqURI PackageIdentifier where
  fromReqURI = simpleParse

impl =
  [ dir "packages" [ path $ handlePackageById
                   , dir "download"
                     [ path $ downloadPackageById ]
                   , method GET $ do
                       liftIO fetchPackagesPage
                   ]
--  , dir "test"     [ support [("text/plain", ok $ toResponse "plain" )
--                             ,("text/html", ok $ toResponse "html" )] ]
  , dir "upload" [ withDataFn (lookInput "upload") $ \input ->
                       [ anyRequest $
                         do ret <- liftIO $ unpackPackage (fromMaybe "noname" $ inputFilename input) (inputValue input)
                            case ret of
                              Left err -> ok $ toResponse $ err
                              Right (pkgDesc, warns) ->
                                  do store <- liftIO $ Blob.open "packages"
                                     blobId <- liftIO $ Blob.add store (inputValue input)
                                     ok $ toResponse "Package valid"
                       ]
                 , fileServe [] "upload.html"
                 ]
  , dir "00-index.tar.gz" [ method GET $ do tarball <- liftIO $ fetchIndexTarball
                                            ok $ toResponse $ Tarball tarball ]
  , fileServe ["hackage.html"] "static"
  ]

