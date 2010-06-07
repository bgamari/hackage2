{-
Create a tarball with the following structure:


backup-timestamp/
  users/
   auth.csv        - users DB
   permissions.csv - permissions DB

  package/
    package-id/
     package-id.tar/
       package.cabal      -- package description
       package-id.tar.gz  -- uploaded tarbal
       uploads.csv        -- upload log (who/when)
     documentation.tar.gz -- optional

  build-reports/
       <n>/
        buildreport
        buildlog        -- optional

  distros/
    <distroname>.csv  -- we have one csv file per known distribution
-}

{-# LANGUAGE ScopedTypeVariables #-}

module Distribution.Server.Export
    ( export
    ) where

import Distribution.Simple.Utils (toUTF8)
import qualified Data.ByteString.Lazy.Char8 as BS8

import Text.CSV hiding (csv)

import qualified Data.Map as Map
import Data.Maybe (catMaybes)

import Distribution.Server.Export.FlatFiles

import qualified Distribution.Server.Util.BlobStorage as Blob

import Distribution.Server.BuildReport.BuildReports (BuildReports)
import qualified Distribution.Server.BuildReport.BuildReports as Build
import qualified Distribution.Server.BuildReport.BuildReport as Build

import Distribution.Server.Distributions.Distributions
    (DistroName, Distributions, DistroVersions)
import qualified Distribution.Server.Distributions.Distributions as Distros

import Distribution.Server.Users.Users (Users)

import Distribution.Server.Packages.Types
import Distribution.Server.Packages.State
import Distribution.Server.PackageIndex
import Distribution.Package

import Distribution.Server.Util.BlobStorage

import Distribution.Text

import qualified Data.ByteString.Lazy as BSL
import Codec.Compression.GZip (compress)
import qualified Codec.Archive.Tar as Tar
import qualified Codec.Archive.Tar.Entry as Tar

import System.FilePath
import System.Locale
import System.IO.Unsafe (unsafeInterleaveIO)
import Data.Time


export :: Users
       -> PackageIndex PkgInfo
       -> Documentation
       -> BuildReports
       -> BlobStorage
       -> Distributions
       -> DistroVersions
       -> IO BSL.ByteString
export users pkgs docs reports storage dists distInfo
    = (compress . Tar.write) `fmap` tarball
 where
   tarball :: IO [Tar.Entry]
       = mkExportEntries users pkgs docs reports storage dists distInfo

mkExportEntries :: Users
                -> PackageIndex PkgInfo
                -> Documentation
                -> BuildReports
                -> BlobStorage
                -> Distributions
                -> DistroVersions
                -> IO [Tar.Entry]
mkExportEntries users pkgs docs reports storage dists distInfo
    = do

  baseDir <- mkBaseDir `fmap` getCurrentTime
  packageEntries <- mkPackageEntries baseDir pkgs docs reports storage
  
  return $ concat
    [ mkUserEntries baseDir users
    , mkDistroEntries baseDir dists distInfo
    , packageEntries
    ]

mkBaseDir :: UTCTime -> FilePath
mkBaseDir time = "export-" ++ formatTime defaultTimeLocale (iso8601DateFormat Nothing) time


mkPackageEntries :: FilePath
                 -> PackageIndex PkgInfo
                 -> Documentation
                 -> BuildReports
                 -> BlobStorage
                 -> IO [Tar.Entry]
mkPackageEntries baseDir pkgs docs reports storage
    = let pkgList = allPackages pkgs
      in unsafeInterleaveConcatMap
             (mkPackageEntry baseDir storage docs reports) pkgList

{- let's be crazy lazy

   The only non-pure operations we do are reading files
   from the blob-storage, which is already lazy IO.

   So we may as well not force the spine of the tar-ball
   before we need to.
-}
unsafeInterleaveConcatMap :: (a -> IO [b]) -> [a] -> IO [b]
unsafeInterleaveConcatMap f = go 

 where go [] = return []
       go (x:xs) = do
         ys <- f x
         yss <- unsafeInterleaveIO $ go xs
         return (ys++yss)

mkPackageEntry :: FilePath
               -> BlobStorage
               -> Documentation
               -> BuildReports
               -> PkgInfo
               -> IO [Tar.Entry]
mkPackageEntry baseDir storage docs reports pkgInfo
    = do

  -- docs and build reports each ship separate
  docsEntry <- mkDocumentationEntry baseDir pkgInfo docs storage
  buildReportEntries <- mkBuildReportEntries baseDir pkgInfo reports storage

  -- the source, uploads, and cabal files get lumped together in their
  -- own tar file
  sourceEntry <- mkSourceEntry pkgInfo storage
  let uploadsEntry = csvToEntry (uploadsToCSV pkgInfo) $
                     "uploads" <.> "csv"
      cabalEntry = mkCabalEntry pkgInfo

      pkgTar = Tar.write $ catMaybes
               [ sourceEntry
               , Just cabalEntry
               , Just uploadsEntry
               ]
      pkgEntry
          = bsToEntry pkgTar $
            pkgEntryPath baseDir pkgInfo <.> "tar"
  return $ pkgEntry : maybe [] return docsEntry ++ buildReportEntries


-- | Tar entry for the source tarball
mkSourceEntry :: PkgInfo -> BlobStorage -> IO (Maybe Tar.Entry)
mkSourceEntry pkgInfo storage
    = case pkgTarball pkgInfo of
        []        -> return Nothing
        ((blob, _):_) -> Just `fmap` (mkBlobEntry storage blob $
                         display (packageName pkgInfo) <.> "tar" <.> "gz")

-- | Tar entry for the documentation for this package
mkDocumentationEntry
    :: Package pkg => FilePath -> pkg -> Documentation
    -> BlobStorage -> IO (Maybe Tar.Entry)
mkDocumentationEntry baseDir pkgInfo (Documentation docs) storage
    = case Map.lookup (packageId pkgInfo) docs of
        Nothing   -> return Nothing
        Just blob -> Just `fmap` (mkBlobEntry storage blob $
                     pkgEntryPath baseDir pkgInfo </> "documentation" <.> "tar")

-- | Tar entries for build reports.
--
-- NOTE - there's no current way to export
-- build reports that correspond to package ids
-- that are not in the passed-in package index
mkBuildReportEntries
    :: Package pkg => FilePath -> pkg -> BuildReports
    -> BlobStorage -> IO [Tar.Entry]
mkBuildReportEntries baseDir pkgInfo reports storage
    = flip concatMapM
      (Build.lookupPackageReports reports (packageId pkgInfo))

      $ \(reportId, report) ->
          case Build.lookupBuildLog reports reportId of
            Nothing -> return [mkBuildReportEntry baseDir reportId report]
            Just (Build.BuildLog blob) -> do
              buildLogEntry <- mkBuildLogEntry baseDir reportId blob storage
              let buildReportEntry = mkBuildReportEntry baseDir reportId report
              return [buildReportEntry, buildLogEntry]

-- | Tar entry for a single build report
mkBuildReportEntry :: FilePath -> Build.BuildReportId
                   -> Build.BuildReport -> Tar.Entry
mkBuildReportEntry baseDir reportId report
    = bsToEntry (stringToBytes . Build.show $ report) $
      reportBasePath baseDir reportId </> "report.txt"

-- | Tar entry for a single build log
mkBuildLogEntry :: FilePath -> Build.BuildReportId         
                -> BlobId -> BlobStorage -> IO Tar.Entry
mkBuildLogEntry baseDir reportId blob storage
    = mkBlobEntry storage blob $
      reportBasePath baseDir reportId </> "log.txt"

reportBasePath :: FilePath -> Build.BuildReportId -> FilePath
reportBasePath baseDir reportId
    = baseDir </> "build-reports" </> display reportId


-- | Tar entry for the .cabal file
mkCabalEntry :: PkgInfo -> Tar.Entry
mkCabalEntry pkgInfo
    = bsToEntry (pkgData pkgInfo) $
      (display $ packageName pkgInfo)  <.> "cabal"


pkgEntryPath :: Package a => FilePath -> a -> FilePath
pkgEntryPath baseDir pkgInfo
    = baseDir
      </> "package"
      </> (display . packageName $ pkgInfo)
      </> (display . packageId $ pkgInfo)


-- | Tar entry for the users db
mkUserEntries :: FilePath -> Users -> [Tar.Entry]
mkUserEntries baseDir users
    = return $ csvToEntry (usersToCSV users) $
      baseDir </> "users" </> "auth" <.> "csv"

-- | Tar entries fr distribution packaging information.
mkDistroEntries :: FilePath -> Distributions -> DistroVersions -> [Tar.Entry]
mkDistroEntries baseDir dists distInfo
    = flip map (Distros.enumerate dists) $ \distro ->
      csvToEntry (distroToCSV distro distInfo) (distroPath baseDir distro)

distroPath :: FilePath -> DistroName -> FilePath
distroPath baseDir distro
    = baseDir </> "distros" </> display distro <.> "csv"

-- | Create a tar entry for an entry
-- in the blob store
mkBlobEntry :: BlobStorage -> BlobId -> FilePath -> IO Tar.Entry
mkBlobEntry storage blob path
    = do
  contents <- Blob.fetch storage blob
  return $ bsToEntry contents path

-- | Convert a CSV to a tar entry (UTF8)
csvToEntry :: CSV -> FilePath -> Tar.Entry
csvToEntry csv path
    = let chunk = csvToBytes csv
      in bsToEntry chunk path

-- | Convert a ByteString to a tar entry
bsToEntry :: BSL.ByteString -> FilePath -> Tar.Entry
bsToEntry chunk path
    = case Tar.toTarPath False path of
        Right tarPath -> Tar.fileEntry tarPath chunk
        Left err -> error $ "Error in export: " ++ err

-- via UTF8 conversion.
stringToBytes :: String -> BSL.ByteString
stringToBytes = BS8.pack . toUTF8

csvToBytes :: CSV -> BSL.ByteString
csvToBytes = stringToBytes . printCSV

concatM :: (Monad m, Functor m) => [m [a]] -> m [a]
concatM x = concat `fmap` sequence x

concatMapM :: (Monad m, Functor m) => (a -> m [b]) -> [a] -> m [b]
concatMapM f xs = concatM $ map f xs
