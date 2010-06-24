module Distribution.Server.Features.Reports (
    ReportsFeature(..),
    ReportsResource(..),
    initReportsFeature
  ) where

import Distribution.Server.Feature
import Distribution.Server.Resource
import Distribution.Server.Features.Core
import Distribution.Server.Types
--import Distribution.Server.Backup.Import
--import Distribution.Server.Backup.Export

import Distribution.Server.BuildReport.ReportsBackup
import Distribution.Server.BuildReport.State
import qualified Distribution.Server.BuildReport.BuildReport as BuildReport
import Distribution.Server.BuildReport.BuildReport (BuildReport(..))
import Distribution.Server.BuildReport.BuildReports (BuildReportId(..), BuildLog(..))
--import qualified Distribution.Server.BuildReport.BuildReports as BuildReports

import Distribution.Server.Packages.Types
import qualified Distribution.Server.Util.BlobStorage as BlobStorage
import Distribution.Server.Backup.Export
--import Distribution.Server.Util.BlobStorage (BlobStorage)

import Distribution.Text
import Distribution.Package

import Happstack.Server
import Happstack.State (update, query)
import Control.Monad.Trans
import qualified Data.ByteString.Lazy.Char8 as BS

data ReportsFeature = ReportsFeature {
    reportsResource :: ReportsResource
}

data ReportsResource = ReportsResource {
    reportsList :: Resource,
    reportsPage :: Resource,
    reportsLog  :: Resource
}

instance HackageFeature ReportsFeature where
    getFeature reports = HackageModule
      { featureName = "packages"
      , resources   = map ($reportsResource reports) [reportsList, reportsPage, reportsLog]
      , dumpBackup    = Just $ \storage -> do
            buildReps <- query GetBuildReports
            exports <- readExportBlobs storage (buildReportsToExport buildReps)
            return exports
      , restoreBackup = Just $ \storage -> reportsBackup storage
      }

initReportsFeature :: CoreFeature -> IO ReportsFeature
initReportsFeature _ = do
    return ReportsFeature
      { reportsResource = ReportsResource
          { reportsList = (resourceAt "/package/:package/reports/.:format") { resourceGet = [("txt", textPackageReports)], resourcePost = [("", submitBuildReport)] }
          , reportsPage = (resourceAt "/package/:package/reports/:id.:format") { resourceGet = [("txt", textPackageReport)], resourceDelete = [("", deleteBuildReport)] }
          , reportsLog  = (resourceAt "/package/:package/reports/:id/log") { resourceGet = [("txt", serveBuildLog)], resourceDelete = [("", deleteBuildLog)], resourcePut = [("", putBuildLog)] }
          }
      }
  where
    textPackageReports _ dpath = withPackagePath dpath $ \_ pkg _ -> do
        reportList <- query $ LookupPackageReports (pkgInfoId pkg)
        return . toResponse $ show reportList
    textPackageReport _ dpath = withPackagePath dpath $ \_ pkg _ -> withPackageReport dpath (pkgInfoId pkg) $ \reportId (report, mlog) -> do
        return . toResponse $ unlines ["Report #" ++ display reportId, show report, maybe "No build log" (const "Build log exists") mlog]

    serveBuildLog config dpath = withPackagePath dpath $ \_ pkg _ -> withPackageReport dpath (pkgInfoId pkg) $ \_ (_, mlog) -> case mlog of
        Nothing -> notFound $ toResponse ""
        Just (BuildLog blobId) -> do
            file <- liftIO $ BlobStorage.fetch (serverStore config) blobId
            return . toResponse $ BS.unpack file

    submitBuildReport config dpath = withPackagePath dpath $ \_ pkg _ -> do
        let pkgid = pkgInfoId pkg
            report = undefined
            mbuildLog = Just $ undefined (serverStore config)
        reportId <- update $ AddReport pkgid (report, mbuildLog)
        goToReport pkgid reportId

    deleteBuildReport _ dpath = withPackagePath dpath $ \_ pkg _ -> withReportId dpath $ \reportId -> do
        let pkgid = pkgInfoId pkg
        success <- update $ DeleteReport pkgid reportId
        if success
            then seeOther ("/package/" ++ display pkgid ++ "/reports/") $ toResponse ()
            else notFound $ toResponse $ "Build report #" ++ display reportId ++ " not found"

    putBuildLog config dpath = withPackagePath dpath $ \_ pkg _ -> withReportId dpath $ \reportId -> do
        let pkgid = pkgInfoId pkg
            buildLog = undefined (serverStore config)
        update $ SetBuildLog pkgid reportId (Just buildLog)
        goToReport pkgid reportId

    deleteBuildLog _ dpath = withPackagePath dpath $ \_ pkg _ -> withReportId dpath $ \reportId -> do
        let pkgid = pkgInfoId pkg
        update $ SetBuildLog pkgid reportId Nothing
        goToReport pkgid reportId

    -- todo: use URIGen.. although it's clunky at the moment
    goToReport pkgid reportId = seeOther ("/package/" ++ display pkgid ++ "/reports/" ++ display reportId) $ toResponse ()

withReportId :: DynamicPath -> (BuildReportId -> ServerPart Response) -> ServerPart Response
withReportId dpath func = case simpleParse =<< lookup "id" dpath of
    Nothing -> notFound $ toResponse "Not a valid report id"
    Just reportId -> func reportId

withPackageReport :: DynamicPath -> PackageId -> (BuildReportId -> (BuildReport, Maybe BuildLog) -> ServerPart Response) -> ServerPart Response
withPackageReport dpath pkgid func = withReportId dpath $ \reportId -> do
    mreport <- query $ LookupReport pkgid reportId
    case mreport of
        Nothing -> notFound $ toResponse "Build report does not exist"
        Just report -> func reportId report

