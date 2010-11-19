module Distribution.Server.Features.Documentation (
    DocumentationFeature(..),
    DocumentationResource(..),
    initDocumentationFeature
  ) where

import Distribution.Server.Feature
import Distribution.Server.Resource
import Distribution.Server.Features.Upload
import Distribution.Server.Features.Core
import Distribution.Server.Types
import Distribution.Server.Error

import Distribution.Server.Packages.State
import Distribution.Server.Backup.Export
import Distribution.Server.Backup.Import
import qualified Distribution.Server.ResourceTypes as Resource
import Distribution.Server.Util.BlobStorage (BlobId, BlobStorage)
import qualified Distribution.Server.Util.BlobStorage as BlobStorage
import qualified Distribution.Server.Util.Serve as TarIndex
import Data.TarIndex (TarIndex)

import Distribution.Text
import Distribution.Package

import Happstack.Server
import Happstack.State (update, query)
import Data.Function
import Control.Monad.Trans
import Control.Monad (mzero)
import qualified Data.Map as Map
import qualified Codec.Compression.GZip as GZip
import Data.ByteString.Lazy.Char8 (ByteString)
import Control.Monad.State (modify)

-- TODO:
-- 1. Write an HTML view for organizing uploads
-- 2. Have cabal generate a standard doc tarball, and serve that here
data DocumentationFeature = DocumentationFeature {
    documentationResource :: DocumentationResource
}

data DocumentationResource = DocumentationResource {
    packageDocs :: Resource,
    packageDocsUpload :: Resource,
    packageDocTar :: Resource,
    packageDocUri :: PackageId -> String -> String
}

instance HackageFeature DocumentationFeature where
    getFeature docs = HackageModule
      { featureName = "documentation"
      , resources   = map ($documentationResource docs) [packageDocs, packageDocTar, packageDocsUpload]
      , dumpBackup    = Just $ \storage -> do
            doc <- query GetDocumentation
            let exportFunc (pkgid, (blob, _)) = ([display pkgid, "documentation.tar"], Right blob)
            readExportBlobs storage . map exportFunc . Map.toList $ documentation doc
      , restoreBackup = Just $ \storage -> updateDocumentation storage (Documentation Map.empty)
      }

initDocumentationFeature :: Config -> CoreFeature -> UploadFeature -> IO DocumentationFeature
initDocumentationFeature config _ _ = do
    let store = serverStore config
    return DocumentationFeature
      { documentationResource = fix $ \r -> DocumentationResource
          { packageDocs = (resourceAt "/package/:package/doc/..") { resourceGet = [("", textResponse . serveDocumentation store)] }
          , packageDocsUpload = (resourceAt "/package/:package/doc/.:format") { resourcePut = [("txt", textResponse . uploadDocumentation store)] }
          , packageDocTar = (resourceAt "/package/:package/:doc.tar") { resourceGet = [("tar", textResponse . serveDocumentationTar store)] }
          , packageDocUri = \pkgid str -> renderResource (packageDocs r) [display pkgid, str]
          }
      }
  where

serveDocumentationTar :: BlobStorage -> DynamicPath -> MServerPart Response
serveDocumentationTar store dpath = withDocumentation dpath $ \_ blob _ -> do
    file <- liftIO $ BlobStorage.fetch store blob
    returnOk $ toResponse $ Resource.DocTarball file blob


-- return: not-found error or tarball
serveDocumentation :: BlobStorage -> DynamicPath -> MServerPart Response
serveDocumentation store dpath = withDocumentation dpath $ \pkgid blob index -> do
    let tarball = BlobStorage.filepath store blob
    -- if given a directory, the default page is index.html
    -- the default directory prefix is the package name itself
    Right `fmap` TarIndex.serveTarball ["index.html"] (display $ packageName pkgid) tarball index

-- return: not-found error (parsing) or see other uri
uploadDocumentation :: BlobStorage -> DynamicPath -> MServerPart Response
uploadDocumentation store dpath = withPackageId dpath $ \pkgid ->
                                  withPackageAuth pkgid $ \_ _ ->
                                  withRequest $ \req -> do
        -- The order of operations:
        -- * Insert new documentation into blob store
        -- * Generate the new index
        -- * Drop the index for the old tar-file
        -- * Link the new documentation to the package
        let Body fileContents = rqBody req
        blob <- liftIO $ BlobStorage.add store (GZip.decompress fileContents)
        tarIndex <- liftIO $ TarIndex.readTarIndex (BlobStorage.filepath store blob)
        update $ InsertDocumentation pkgid blob tarIndex
        fmap Right $ seeOther ("/package/" ++ display pkgid) (toResponse ())

-- curl -u mgruen:admin -X PUT --data-binary @gtk.tar.gz http://localhost:8080/package/gtk-0.11.0

withDocumentation :: DynamicPath -> (PackageId -> BlobId -> TarIndex -> MServerPart a) -> MServerPart a
withDocumentation dpath func =
    withPackagePath dpath $ \pkg _ -> do
    let pkgid = packageId pkg
    mdocs <- query $ LookupDocumentation pkgid
    case mdocs of
      Nothing -> returnError 404 "Not Found" [MText $ "There is no documentation for " ++ display pkgid]
      Just (blob, index) -> func pkgid blob index

---- Import 
updateDocumentation :: BlobStorage -> Documentation -> RestoreBackup
updateDocumentation store docs = fix $ \r -> RestoreBackup
  { restoreEntry = \(path, bs) ->
        case path of
            [str, "documentation.tar"] | Just pkgid <- simpleParse str -> do
                res <- runImport docs (importDocumentation store pkgid bs)
                return $ fmap (updateDocumentation store) res
            _ -> return . Right $ r
  , restoreFinalize = return . Right $ r
  , restoreComplete = update $ ReplaceDocumentation docs
  }

importDocumentation :: BlobStorage -> PackageId
                    -> ByteString -> Import Documentation ()
importDocumentation store pkgid doc = do
    blobId <- liftIO $ BlobStorage.add store doc
    -- this may fail for a bad tarball
    tarred <- liftIO $ TarIndex.readTarIndex (BlobStorage.filepath store blobId)
    modify $ Documentation . Map.insert pkgid (blobId, tarred) . documentation

