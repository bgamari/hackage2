module Distribution.Server.Features.Check (
    CheckFeature(..),
    CheckResource(..),    
    initCheckFeature,

    postCandidate,
    postPackageCandidate,
    putPackageCandidate,
    doDeleteCandidate,
    uploadCandidate,
    publishCandidate,
    checkPublish,

    CandidateRender(..),
    doCandidateRender,

    withCandidatePath,
    withCandidate,
    withCandidates
  ) where

import Distribution.Server.Feature
import Distribution.Server.Resource
import Distribution.Server.Types
import Distribution.Server.Error
import Distribution.Server.Hook
import Distribution.Server.Features.Core
import Distribution.Server.Features.Packages
import Distribution.Server.Features.Upload

import Distribution.Server.Packages.State
import Distribution.Server.Packages.Types
import Distribution.Server.Users.State (GetUserDb(..))
import qualified Distribution.Server.Users.Types as Users
import qualified Distribution.Server.Users.Users as Users
import qualified Distribution.Server.Users.Group as Group
import qualified Distribution.Server.Util.BlobStorage as BlobStorage
import Distribution.Server.Util.BlobStorage (BlobStorage)
import qualified Distribution.Server.PackageIndex as PackageIndex
import Distribution.Server.PackageIndex (PackageIndex)
import qualified Distribution.Server.ResourceTypes as Resource

import Distribution.Text
import Distribution.Package
import Data.Version
import Happstack.Server
import Happstack.State
import Text.XHtml.Strict (unordList, h3, (<<), toHtml)
import Data.Function (fix)
import Data.List (find)
import Control.Monad (guard, unless, when, mzero)
import Control.Monad.Trans (liftIO)
import Data.Time.Clock (getCurrentTime)


data CheckFeature = CheckFeature {
    checkResource :: CheckResource,
    candidateRender :: CandPkgInfo -> IO CandidateRender
}

data CheckResource = CheckResource {
    candidatesPage :: Resource,
    candidatePage :: Resource,
    packageCandidatesPage :: Resource,
    publishPage :: Resource,
    candidateCabal :: Resource,
    candidateTarball :: Resource,
    -- there can also be build reports - can use the same package id index
    candidatesUri :: String -> String,
    candidateUri :: String -> PackageId -> String,
    packageCandidatesUri :: String -> PackageId -> String,
    publishUri   :: String -> PackageId -> String,
    candidateTarballUri :: PackageId -> String,
    candidateCabalUri :: PackageId -> String
}


-- candidates can be published at any time. there is one candidate per package.
-- they can be deleted, but it's not required

instance HackageFeature CheckFeature where
    getFeature check = HackageModule
      { featureName = "check"
      , resources   = map ($checkResource check) [candidatesPage, candidatePage, publishPage, candidateCabal, candidateTarball]
      , dumpBackup    = Nothing
      , restoreBackup = Nothing
      }

-- URI generation (string-based), using maps; user groups
initCheckFeature :: Config -> CoreFeature -> PackagesFeature -> UploadFeature -> IO CheckFeature
initCheckFeature config core _ _ = do
    let store = serverStore config
    return CheckFeature
      { checkResource = fix $ \r -> CheckResource
          { candidatesPage = (resourceAt "/packages/candidates/.:format") { resourceGet = [("txt", textCandidatesPage)], resourcePost = [("txt", \_ -> textResponse $ postCandidate r store)] }
          , candidatePage = (resourceAt "/package/:package/candidate.:format") { resourceGet = [("html", basicCandidatePage r)], resourcePut = [("html", textResponse . putPackageCandidate r store)], resourceDelete = [("", textResponse . doDeleteCandidate r)] }
          , packageCandidatesPage = (resourceAt "/package/:package/candidates/.:format") { resourceGet = [("txt", textPkgCandidatesPage r)], resourcePost = [("", textResponse . postPackageCandidate r store)] }
          , publishPage = (resourceAt "/package/:package/candidate/publish.:format") { resourceGet = [("txt", textPublishForm)], resourcePost = [("", textPostPublish)] }
          , candidateCabal = (resourceAt "/package/:package/candidate/:cabal.cabal") { resourceGet = [("cabal", serveCandidateCabal)] }
          , candidateTarball = (resourceAt "/package/:package/candidate/:tarball.tar.gz") { resourceGet = [("tarball", serveCandidateTarball store)] }

          , candidatesUri = \format -> renderResource (candidatesPage r) [format]
          , candidateUri  = \format pkgid -> renderResource (candidatePage r) [display pkgid, format]
          , packageCandidatesUri = \format pkgid -> renderResource (packageCandidatesPage r) [display pkgid, format]
          , publishUri = \format pkgid -> renderResource (publishPage r) [display pkgid, format]
          , candidateTarballUri = \pkgid -> renderResource (candidateTarball r) [display pkgid, display pkgid]
          , candidateCabalUri = \pkgid -> renderResource (candidateCabal r) [display pkgid, display (packageName pkgid)]
          }
      , candidateRender = \pkg -> do
            users <- query GetUserDb
            state <- query GetPackagesState
            return $ doCandidateRender (packageList state) users pkg
      }

  where
    basicCandidatePage :: CheckResource -> DynamicPath -> ServerPart Response
    basicCandidatePage r dpath = withPackageId dpath $ \pkgid ->
                                 withCandidate pkgid $ \_ mpkg _ ->
                                 ok . toResponse . Resource.XHtml $ case mpkg of
        Nothing  -> toHtml $ "A candidate for " ++ display pkgid ++ " doesn't exist"
        Just pkg -> toHtml [ h3 << "Downloads"
                           , toHtml (section pkg)
                           , h3 << "Warnings"
                           , case candWarnings pkg of
                                [] -> toHtml "No warnings"
                                warnings -> unordList warnings
                           ]
      where section cand = basicPackageSection (candidateCabalUri r) (candidateTarballUri r) (candPkgInfo cand)

    textCandidatesPage _ = return . toResponse $ "Insert list of candidate packages here"

    textPkgCandidatesPage _ dpath = withPackageName dpath $ \name ->
                                    withCandidates name $ \_ _ -> do
        return . toResponse $ "Insert list of candidate packages here"
    textPublishForm :: DynamicPath -> ServerPart Response
    textPublishForm dpath = textResponse $
                            withCandidatePath dpath $ \_ candidate -> do
        withPackageAuth candidate $ \_ _ -> do
        packages <- fmap packageList $ query GetPackagesState
        case checkPublish packages candidate of
            Just err -> returnError' err
            Nothing  -> returnOk $ toResponse "Post here to publish the package"

    textPostPublish :: DynamicPath -> ServerPart Response
    textPostPublish dpath = do
        res <- publishCandidate core dpath False
        case res of
            Left err -> makeTextError err
            Right uresult -> ok $ toResponse $ unlines (uploadWarnings uresult)

postCandidate :: CheckResource -> BlobStorage -> MServerPart Response
postCandidate r store = do
    res <- uploadCandidate (const True) store
    respondToResult r res

-- POST to /:package/candidates/
postPackageCandidate :: CheckResource -> BlobStorage -> DynamicPath -> MServerPart Response
postPackageCandidate r store dpath = withPackageName dpath $ \name -> do
    res <- uploadCandidate ((==name) . packageName) store
    respondToResult r res

-- PUT to /:package-version/candidate
putPackageCandidate :: CheckResource -> BlobStorage -> DynamicPath -> MServerPart Response
putPackageCandidate r store dpath = withPackageId dpath $ \pkgid -> do
    guard (packageVersion pkgid /= Version [] [])
    res <- uploadCandidate (==pkgid) store
    respondToResult r res

respondToResult :: CheckResource -> Either ErrorResponse CandPkgInfo -> MServerPart Response
respondToResult r res = case res of
    Left err -> returnError' err
    Right pkgInfo -> fmap Right $ seeOther (candidateUri r "" $ packageId pkgInfo) (toResponse ())

doDeleteCandidate :: CheckResource -> DynamicPath -> MServerPart Response
doDeleteCandidate r dpath = withCandidatePath dpath $ \_ candidate -> do
    withPackageAuth candidate $ \_ _ -> do
    update $ DeleteCandidate (packageId candidate)
    fmap Right $ seeOther (packageCandidatesUri r "" $ packageId candidate) $ toResponse ()

serveCandidateTarball :: BlobStorage -> DynamicPath -> ServerPart Response
serveCandidateTarball store dpath = withPackageTarball dpath $ \pkgid ->
                                    withCandidate pkgid $ \_ mpkg _ -> case mpkg of
    Nothing -> mzero -- candidate  does not exist
    Just pkg -> case pkgTarball (candPkgInfo pkg) of
        [] -> mzero --candidate's tarball does not exist
        ((blobId, _):_) -> do
            file <- liftIO $ BlobStorage.fetch store blobId
            ok $ toResponse $ Resource.PackageTarball file blobId (pkgUploadTime $ candPkgInfo pkg)

--withFormat :: DynamicPath -> (String -> a) -> a
serveCandidateCabal :: DynamicPath -> ServerPart Response
serveCandidateCabal dpath = do
    mres <- withCandidatePath dpath $ \_ pkg -> do
        guard (lookup "cabal" dpath == Just (display $ packageName pkg))
        returnOk $ toResponse (Resource.CabalFile (pkgData $ candPkgInfo pkg))
    case mres of
        Right res -> return res
        Left {}   -> mzero

uploadCandidate :: (PackageId -> Bool) -> BlobStorage -> MServerPart CandPkgInfo
uploadCandidate isRight storage = do
    regularIndex <- fmap packageList $ query GetPackagesState
    -- ensure that the user has proper auth if the package exists
    res <- extractPackage (processCandidate isRight regularIndex) storage
    case res of
        Left failed -> returnError' failed
        Right (pkgInfo, uresult) -> do
            let candidate = CandPkgInfo {
                    candInfoId = packageId pkgInfo,
                    candPkgInfo = pkgInfo,
                    candWarnings = uploadWarnings uresult,
                    candPublic = True -- do withDataFn
                }
            update $ AddCandidate candidate
            unless (packageExists regularIndex pkgInfo) $ update $ AddPackageMaintainer (packageName pkgInfo) (pkgUploadUser pkgInfo)
            returnOk candidate

-- | Helper function for uploadCandidate.
processCandidate :: (PackageId -> Bool) -> PackageIndex PkgInfo -> Users.UserId -> UploadResult -> IO (Maybe ErrorResponse)
processCandidate isRight state uid res = do
    let pkg = packageId (uploadDesc res)
    if not (isRight pkg)
      then uploadFailed "Name of package or package version does not match"
      else do
        pkgGroup <- getPackageGroup (packageName pkg)
        if packageExists state pkg && not (uid `Group.member` pkgGroup)
          then uploadFailed "Not authorized to upload a candidate for this package"
          else return Nothing
  where uploadFailed = return . Just . ErrorResponse 403 "Upload failed" . return . MText

publishCandidate :: CoreFeature -> DynamicPath -> Bool -> MServerPart UploadResult
publishCandidate core dpath doDelete = do
    packages <- fmap packageList $ query GetPackagesState
    withCandidatePath dpath $ \_ candidate -> do
    -- check authorization to upload - must already be a maintainer
    withPackageAuth candidate $ \uid _ -> do
    -- check if package or later already exists
    case checkPublish packages candidate of
        Just failed -> returnError' failed
        Nothing -> do
            uploadData <- fmap (flip (,) uid) (liftIO getCurrentTime)
            let pkgInfo = candPkgInfo candidate
            success <- update $ InsertPkgIfAbsent PkgInfo {
                pkgInfoId     = packageId candidate,
                pkgDesc       = pkgDesc pkgInfo,
                pkgData       = pkgData pkgInfo,
                pkgTarball    = case pkgTarball pkgInfo of
                    ((blobId, _):_) -> [(blobId, uploadData)]
                    [] -> [], -- this shouldn't happen, but let's keep this part total anyway
                pkgUploadData = uploadData,
                pkgDataOld    = []
            }
            if success
              then do
                -- delete when requested ("moving" the resource)
                when doDelete $ update $ DeleteCandidate (packageId candidate)
                liftIO $ runHook' (packageAddHook core) pkgInfo
                liftIO $ runHook (packageIndexChange core)
                returnOk $ UploadResult (pkgDesc pkgInfo) (pkgData pkgInfo) (candWarnings candidate)
              else returnError 403 "Upload failed" [MText "Package already exists."]


-- | Helper function for publishCandidate that ensures it's safe to insert into the main index.
checkPublish :: PackageIndex PkgInfo -> CandPkgInfo -> Maybe ErrorResponse
checkPublish packages candidate = do
    let pkgs = PackageIndex.lookupPackageName packages (packageName candidate)
        candVersion = packageVersion candidate
    case find ((== candVersion) . packageVersion) pkgs of
        Just {} -> Just $ ErrorResponse 403 "Publish failed" [MText "Package name and version already exist in the database"]
        Nothing  -> Nothing
--      Nothing -> case find ((> candVersion) . packageVersion) pkgs of
--          Just pkg -> forbidden error here: "Later versions exist in the database than the candidate ("
--                                             ++display (packageVersion pkg)++" > "++display candVersion++ ")"

------------------------------------------------------------------------------
data CandidateRender = CandidateRender {
    candPackageRender :: PackageRender,
    renderWarnings :: [String],
    hasIndexedPackage :: Bool
}

doCandidateRender :: PackageIndex PkgInfo -> Users.Users -> CandPkgInfo -> CandidateRender
doCandidateRender index users cand =
    let render = doPackageRender users (candPkgInfo cand)
    in CandidateRender {
        candPackageRender = render,
        renderWarnings = candWarnings cand,
        hasIndexedPackage = not . null $ PackageIndex.lookupPackageName index (packageName cand)
    }

------------------------------------------------------------------------------
withCandidatePath :: DynamicPath -> (CandidatePackages -> CandPkgInfo -> MServerPart a) -> MServerPart a
withCandidatePath dpath func = withPackageId dpath $ \pkgid -> withCandidate pkgid $ \state mpkg _ -> case mpkg of
    Nothing  -> returnError 404 "Package not found" [MText $ "Candidate for " ++ display pkgid ++ " does not exist"]
    Just pkg -> func state pkg

withCandidate :: PackageId -> (CandidatePackages -> Maybe CandPkgInfo -> [CandPkgInfo] -> ServerPart a) -> ServerPart a
withCandidate pkgid func = do
    state <- query GetCandidatePackages
    let pkgs = PackageIndex.lookupPackageName (candidateList state) (packageName pkgid)
    func state (find ((==pkgid) . packageId) pkgs) pkgs

withCandidates :: PackageName -> (CandidatePackages -> [CandPkgInfo] -> ServerPart a) -> ServerPart a
withCandidates name func = withCandidate (PackageIdentifier name $ Version [] []) $ \state _ infos -> func state infos

