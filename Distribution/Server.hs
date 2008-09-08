module Distribution.Server (
   Server,
   initialise,
   Config(..),
   defaultConfig,
   run,
   bulkImport,
 ) where

import Distribution.Package ( PackageIdentifier(..), Package(packageId)
                            , packageName, packageVersion )
import Distribution.Text    (simpleParse, display)
import HAppS.Server hiding (port)
import qualified HAppS.Server
import HAppS.State hiding (Version)

import Distribution.Server.State as State hiding (buildReports, bulkImport)
import qualified  Distribution.Server.State as State
import qualified Distribution.Server.Cache as Cache
import qualified Distribution.Simple.PackageIndex as PackageIndex
import Distribution.Server.Types
         ( PkgInfo(..) )
import qualified Distribution.Server.ResourceTypes as Resource
import qualified Distribution.Server.Pages.Index   as Pages (packageIndex)
import qualified Distribution.Server.Pages.Package as Pages
import qualified Distribution.Server.Pages.Recent  as Pages
import qualified Distribution.Server.Pages.BuildReports as Pages
import qualified Distribution.Server.IndexUtils as PackageIndex (write)
import qualified Distribution.Server.PackageUpload.Unpack as Upload (unpackPackage)
import qualified Distribution.Server.Util.BlobStorage as BlobStorage
import Distribution.Server.Util.BlobStorage (BlobStorage)
import qualified Distribution.Server.BuildReport.BuildReport as BuildReport
import qualified Distribution.Server.BuildReport.BuildReports as BuildReports
import qualified Distribution.Server.BulkImport as BulkImport
import qualified Distribution.Server.BulkImport.UploadLog as UploadLog

import System.FilePath ((</>))
import System.Directory
         ( createDirectoryIfMissing, doesDirectoryExist )
import Control.Concurrent.MVar (MVar)
import Data.Maybe; import Data.Version
import Control.Monad.Trans
import Control.Monad (when)
import Data.List (maximumBy, sortBy)
import Data.Ord (comparing)
import qualified Data.Map as Map
import Data.ByteString.Lazy.Char8 (ByteString)
import Data.Time.Clock
import Network.URI
         ( URIAuth(URIAuth) )
import Network.BSD
         ( getHostName )

import qualified Data.ByteString.Lazy.Char8 as BS.Char8
import qualified Codec.Compression.GZip as GZip

import Paths_hackage_server (getDataDir)

data Config = Config {
  confHostName  :: String,
  confPortNum   :: Int,
  confStateDir  :: FilePath,
  confStaticDir :: FilePath
}

defaultConfig :: IO Config
defaultConfig = do
  hostName <- getHostName
  dataDir  <- getDataDir
  return Config {
    confHostName  = hostName,
    confPortNum   = 5000,
    confStateDir  = "state",
    confStaticDir = dataDir </> "static"
  }

data Server = Server {
  serverStore      :: BlobStorage,
  serverStaticDir  :: FilePath,
  serverTxControl  :: MVar TxControl,
  serverCache      :: Cache.Cache,
  serverURI        :: URIAuth,
  serverPort       :: Int
}

initialise :: Config -> IO Server
initialise (Config hostName portNum stateDir staticDir) = do

  exists <- doesDirectoryExist staticDir
  when (not exists) $
    fail $ "The directory '" ++ staticDir ++ "' does not exist. It should "
        ++ "contain the hackage server's static html and other files."

  createDirectoryIfMissing False stateDir
  store   <- BlobStorage.open blobStoreDir

  txCtl   <- runTxSystem (Queue (FileSaver happsStateDir)) hackageEntryPoint
  cache   <- Cache.new =<< stateToCache hostURI =<< query GetPackagesState

  return Server {
    serverStore      = store,
    serverStaticDir  = staticDir,
    serverTxControl  = txCtl,
    serverCache      = cache,
    serverURI        = hostURI,
    serverPort       = portNum
  }

  where
    happsStateDir = stateDir </> "db"
    blobStoreDir  = stateDir </> "blobs"
    hostURI       = URIAuth "" hostName portStr
      where portStr | portNum == 80 = ""
                    | otherwise     = ':' : show portNum

hackageEntryPoint :: Proxy PackagesState
hackageEntryPoint = Proxy

run :: Server -> IO ()
run server = simpleHTTP conf (impl server)
  where
    conf = nullConf { HAppS.Server.port = serverPort server }

bulkImport :: Server
           -> ByteString -> String -> Maybe ByteString
           -> IO [UploadLog.Entry]
bulkImport (Server store _ _ cache host _) indexFile logFile archive = do
  --TODO: check the other two first
  tarballs  <- maybe (return []) (BulkImport.importTarballs store) archive

  (pkgsInfo, badLogEntries) <- either fail return
    (BulkImport.importPkgInfo indexFile logFile tarballs)

  update $ BulkImport pkgsInfo
  Cache.put cache =<< stateToCache host =<< query GetPackagesState

  return badLogEntries

updateCache :: MonadIO m => Cache.Cache -> URIAuth -> m ()
updateCache cache host
    = liftIO (Cache.put cache =<< stateToCache host =<< query GetPackagesState)

stateToCache :: URIAuth -> PackagesState -> IO Cache.State
stateToCache host state = getCurrentTime >>= \now -> return
  Cache.State {
    Cache.packagesPage  = toResponse $ Resource.XHtml $
                            Pages.packageIndex index,
    Cache.indexTarball  = GZip.compress $ PackageIndex.write index,
    Cache.recentChanges = toResponse $ Resource.XHtml $
                            Pages.recentPage recentChanges,
    Cache.packagesFeed  = toResponse $
                            Pages.recentFeed host now recentChanges
  }
  where index = packageList state
        recentChanges = reverse $ sortBy (comparing pkgUploadTime) (PackageIndex.allPackages index)

-- Support the same URL scheme as the first version of hackage.
legacySupport :: ServerPart Response
legacySupport = multi
    [ path $ \name ->
      [ path $ \version ->
        [ let dirName = display pkgid ++ ".tar.gz"
              pkgid = PackageIdentifier {pkgName = name, pkgVersion = version}
          in dir dirName
             [ method GET $ do
                 movedPermanently ("/packages/"++display pkgid++"/tarball") (toResponse "")
             ]
        ]]
    , dir "00-index.tar.gz"
      [ method GET $
               movedPermanently "/00-index.tar.gz" (toResponse "")
      ]
    ]

handlePackageById :: BlobStorage -> PackageIdentifier -> [ServerPart Response]
handlePackageById store pkgid =
  [ method GET $
      withPackage $ \pkg pkgs ->
        ok $ toResponse $ Resource.XHtml $ Pages.packagePage pkg pkgs

  , dir "cabal"
    [ method GET $
      withPackage $ \pkg _pkgs ->
        ok $ toResponse (Resource.CabalFile (pkgData pkg))
--  , method PUT $ do ...
    ]

  , dir "tarball"
    [ method GET $
        withPackage $ \pkg _pkgs -> do
          case pkgTarball pkg of
            Nothing -> notFound $ toResponse "No tarball available"
            Just blobId -> do
              file <- liftIO $ BlobStorage.fetch store blobId
              ok $ toResponse $
                Resource.PackageTarball file blobId (pkgUploadTime pkg)
    ]
  , dir "buildreports"
    [ method GET $ do
        state <- query GetPackagesState
        case PackageIndex.lookupPackageId (packageList state) pkgid of
          Nothing -> notFound $ toResponse "No such package"
          Just _  -> do
            let reports = BuildReports.lookupPackageReports
                            (State.buildReports state) pkgid
            ok $ toResponse $ Resource.XHtml $
                   Pages.buildReportSummary pkgid reports
    ]
  ]
  
  where
    withPackage action = do
      index <- return . packageList =<< query GetPackagesState
      case PackageIndex.lookupPackageName index (packageName pkgid) of
        []   -> notFound $ toResponse "No such package"
        pkgs  | pkgVersion pkgid == Version [] []
             -> action pkg pkgs
          where pkg = maximumBy (comparing packageVersion) pkgs
 
        pkgs -> case listToMaybe [ pkg | pkg <- pkgs, packageVersion pkg
                                               == packageVersion pkgid ] of
          Nothing  -> notFound $ toResponse "No such package version"
          Just pkg -> action pkg pkgs

uploadPackage :: BlobStorage -> Cache.Cache -> URIAuth -> ServerPart Response
uploadPackage store cache host =
  methodSP POST $
    basicAuth "hackage" basicUsers
      [ withDataFn (lookInput "package") $ \input ->
          [ anyRequest $
              let fileName    = (fromMaybe "noname" $ inputFilename input)
                  fileContent = inputValue input
               in upload fileName fileContent
          ]
      ]
  where
    upload name content = do
      --TODO: check if the package is in the index already, before we embark
      -- on writing the tarball into the store and validating etc.
      res <- liftIO $ BlobStorage.addWith store content
                        (Upload.unpackPackage name)
      case res of
        Left  err -> badRequest $ toResponse err
        Right (((pkg, pkgStr), warnings), blobId) -> do
          now <- liftIO $ getCurrentTime
          success <- update $ Insert $ PkgInfo
                                        { pkgInfoId = packageId pkg
                                        , pkgDesc   = pkg
                                        , pkgData   = pkgStr
                                        , pkgTarball= Just blobId
                                        , pkgUploadTime = now
                                        , pkgUploadUser = "Unknown"
                                        , pkgUploadOld  = [] }
          if success
             then do updateCache cache host
                     ok $ toResponse $ unlines warnings
             else forbidden $ toResponse "Package already exist."

buildReports :: BlobStorage -> [ServerPart Response]
buildReports store =
  [ path $ \reportId ->
    [ method GET $ do
        reports <- return . State.buildReports =<< query GetPackagesState
        case BuildReports.lookupReport reports reportId of
          Nothing     -> notFound $ toResponse "No such report"
          Just report ->
            ok $ toResponse $ BuildReport.show report

    , dir "buildlog" $
      [ method GET $ do
          reports <- return . State.buildReports =<< query GetPackagesState
          case BuildReports.lookupBuildLog reports reportId of
            Nothing -> notFound $ toResponse "No build log available"
            Just (BuildReports.BuildLog blobId) -> do
              file <- liftIO $ BlobStorage.fetch store blobId
              ok $ toResponse $
                Resource.BuildLog file

      , methodSP PUT $ withRequest $ \Request { rqBody = Body body } -> do
          reports <- return . State.buildReports =<< query GetPackagesState
          case BuildReports.lookupReport reports reportId of
            Nothing -> notFound $ toResponse "No such report"
            Just _  -> do
              --FIXME: authorisation, depending on report id
              blobId <- liftIO $ BlobStorage.add store body
              update $ AddBuildLog reportId (BuildReports.BuildLog blobId)
              setResponseCode 204
              return $ toResponse ""
      ]
    ]
  , methodSP POST $ withRequest $ \Request { rqBody = Body body } ->
      case BuildReport.parse (BS.Char8.unpack body) of
        Left err -> badRequest $ toResponse err
        Right report -> do
          reportId <- update $ AddReport report
          seeOther ("/buildreports/"++display reportId) $
            toResponse ""
  ]

instance FromReqURI PackageIdentifier where
  fromReqURI = simpleParse

instance FromReqURI Version where
  fromReqURI = simpleParse

instance FromReqURI BuildReports.BuildReportId where
  fromReqURI = simpleParse

basicUsers :: Map.Map String String
basicUsers = Map.fromList [("Lemmih","kodeord")]

impl :: Server -> [ServerPartT IO Response]
impl (Server store static _ cache host _) =
  [ dir "packages" [ path $ handlePackageById store
                   , legacySupport
                   , method GET $ do
                       cacheState <- Cache.get cache
                       ok $ Cache.packagesPage cacheState
                   ]
  , dir "buildreports" (buildReports store)
  , dir "recent.rss"
      [ method GET $ ok . Cache.packagesFeed =<< Cache.get cache ]
  , dir "recent.html"
      [ method GET $ ok . Cache.recentChanges =<< Cache.get cache ]
  , dir "upload"
      [ uploadPackage store cache host ]
  , dir "00-index.tar.gz"
      [ method GET $ do
          cacheState <- Cache.get cache
          ok $ toResponse $ Resource.IndexTarball (Cache.indexTarball cacheState)
      ]
  , fileServe ["hackage.html"] static
  ]
