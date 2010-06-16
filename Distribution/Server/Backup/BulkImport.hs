-----------------------------------------------------------------------------
-- |
-- Module      :  Distribution.Server.BulkImport
-- Copyright   :  (c) Duncan Coutts 2008
-- License     :  BSD-like
--
-- Maintainer  :  duncan@haskell.org
-- Stability   :  provisional
-- Portability :  portable
--
-- Support for importing data from the old hackage server.
-----------------------------------------------------------------------------
module Distribution.Server.Backup.BulkImport (
  importPkgIndex,
  importUploadLog,
  importTarballs,
  importUsers,
  mergePkgInfo,
  ) where

import qualified Distribution.Server.Util.Index as PackageIndex (read)
import qualified Distribution.Server.Users.Users as Users
import           Distribution.Server.Users.Users   (Users)
import qualified Distribution.Server.Users.Types as Users
import qualified Codec.Archive.Tar.Entry as Tar
         ( Entry(..), entryPath, EntryContent(..) )
import qualified Distribution.Server.Backup.UploadLog as UploadLog
import qualified Distribution.Server.Auth.HtPasswdDb as HtPasswdDb
import qualified Distribution.Server.Auth.Types as Auth
import qualified Distribution.Server.Util.BlobStorage as BlobStorage
import Distribution.Server.Util.BlobStorage (BlobStorage)
import Distribution.Server.Packages.Types (PkgInfo(..))

import Distribution.Package
         ( PackageIdentifier, Package(packageId) )
import Distribution.PackageDescription.Parse
         ( parsePackageDescription )
import Distribution.ParseUtils
         ( ParseResult(..), locatedErrorMsg )
import Distribution.Text
         ( display )
import Distribution.Simple.Utils
         ( fromUTF8 )

import System.FilePath
         ( takeExtension )
import Data.ByteString.Lazy.Char8 (ByteString)
import qualified Data.ByteString.Lazy.Char8 as BS
         (  unpack )
import qualified Codec.Compression.GZip as GZip
import Control.Monad.Error () --intance Monad (Either String)
import Data.List
         ( sortBy, foldl' )
import Data.Ord
         ( comparing )

import Prelude hiding (read)

newPkgInfo :: PackageIdentifier
           -> (FilePath, ByteString)
           -> UploadLog.Entry -> [UploadLog.Entry]
           -> Users.Users
           -> Either String PkgInfo
newPkgInfo pkgid (cabalFilePath, cabalFile) (UploadLog.Entry time user _) _ users =
  case parse cabalFile of
      ParseFailed err -> fail $ cabalFilePath
                             ++ maybe "" (\n -> ":" ++ show n) lineno
                             ++ ": " ++ message
        where (lineno, message) = locatedErrorMsg err

      ParseOk _ pkg   -> return PkgInfo {
        pkgInfoId     = pkgid,
        pkgDesc       = pkg,
        pkgData       = cabalFile,
        pkgTarball    = [],
        pkgUploadData = (time, Users.nameToId users user),
        pkgDataOld    = []--[ (time', Users.nameToId users user')
                        -- | UploadLog.Entry time' user' _ <- others]
      }
  where parse = parsePackageDescription . fromUTF8 . BS.unpack

importPkgIndex :: ByteString -> Either String [(PackageIdentifier, Tar.Entry)]
importPkgIndex = PackageIndex.read (,) . GZip.decompress

importUploadLog :: String -> Either String [UploadLog.Entry]
importUploadLog = UploadLog.read

-- | Actually write the tarballs to disk and return an association of
-- 'PackageIdentifier' to the 'BlobStorage.BlobId' of the tarball added to the
-- 'BlobStorage' area.
--
importTarballs :: BlobStorage
               -> Maybe ByteString
               -> IO [(PackageIdentifier, BlobStorage.BlobId)]
importTarballs _      Nothing           = return []
importTarballs store (Just archiveFile) =
  case PackageIndex.read (,) archiveFile of
    Left  problem  -> fail problem
    Right tarballs -> sequence
      [ do blobid <- BlobStorage.add store fileContent
           return (pkgid, blobid)
      | (pkgid, entry@Tar.Entry {
                  Tar.entryContent = Tar.NormalFile fileContent _
                }) <- tarballs
      , takeExtension (Tar.entryPath entry) == ".gz" ] --FIXME: .tar.gz

-- | The active users are simply all those listed in the current htpasswd file.
--
importUsers :: Maybe String -> Either String Users.Users
importUsers Nothing             = Right Users.empty
importUsers (Just htpasswdFile) = importUsers' Users.empty
                              =<< HtPasswdDb.parse htpasswdFile
  where
    importUsers' users [] = Right users
    importUsers' users ((userName, userAuth):rest) =
      case Users.add userName (Users.UserAuth userAuth Auth.BasicAuth) users of
        Nothing                -> Left (alreadyPresent userName)
        Just (users', _userId) -> importUsers' users' rest

    alreadyPresent name = "User " ++ show name ++ " is already present"

-- | All users who have ever uploaded a package must have been a user at some
-- point however it may be that some users who uploaded packages are not
-- current users. However We still need a 'UserId' for these package uploaders
-- so we must create a bunch of historical deleted users.
--
-- Note that we do make the potentially false assumption that if there is a
-- upload log entry from a named user and there is currently such a named user
-- that they are in fact one and the same.
--
mergeDeletedUsers :: [UploadLog.Entry] -> Users -> (Users, Users)
mergeDeletedUsers logEntries users0 =
  let (users1, toDelete) = foldl' addUser (users0, []) logEntries
      users2             = foldl' deleteUser users1 toDelete
   in (users1, users2)

  where
    addUser (users, added) (UploadLog.Entry _ userName _) =
      case Users.add userName dummyAuth users of
        Nothing               -> (users ,        added) -- are already present
        Just (users', userId) -> (users', userId:added) -- shall not be spared from the delete-fold

    dummyAuth = Users.UserAuth (Auth.PasswdHash "") (Auth.BasicAuth)

    deleteUser users userId = users'
      where Just users' = Users.delete userId users

-- | Merge all the package and user info together
--
mergePkgInfo :: [(PackageIdentifier, Tar.Entry)]
             -> [UploadLog.Entry]
             -> [(PackageIdentifier, BlobStorage.BlobId)]
             -> Users.Users
             -> Either String ([PkgInfo], Users.Users, [UploadLog.Entry])
mergePkgInfo pkgDescs logEntries tarballInfo users = do
  let (users', users'') = mergeDeletedUsers logEntries users
      logEntries'       = UploadLog.group logEntries
  (pkgs, extraLogEntries) <- mergeIndexWithUploadLog pkgDescs logEntries' users'
  pkgs' <- mergeTarballs tarballInfo pkgs
  return (pkgs', users'', extraLogEntries)

-- | Merge the package index meta data with the upload log to make initial
--   'PkgInfo' records, but without tarballs.
--
-- Also returns any upload log entries with no corresponding package info.
-- This happens for packages which got uploaded but subsequently deleted.
--
mergeIndexWithUploadLog :: [(PackageIdentifier, Tar.Entry)]
                        -> [(UploadLog.Entry, [UploadLog.Entry])]
                        -> Users.Users
                        -> Either String ([PkgInfo], [UploadLog.Entry])
mergeIndexWithUploadLog pkgs entries users =
  mergePkgs [] [] $
    mergeBy comparingPackageId
      (sortBy (comparing fst)
              [ (pkgid, (path, cabalFile))
              | (pkgid, entry@Tar.Entry {
                          Tar.entryContent = Tar.NormalFile cabalFile _
                        }) <- pkgs
              , let path = Tar.entryPath entry
              , takeExtension path == ".cabal" ])
      (sortBy (comparing (\(UploadLog.Entry _ _ pkgid, _) -> pkgid)) entries)
  where
    comparingPackageId (pkgid, _) (UploadLog.Entry _ _ pkgid', _) =
      compare pkgid pkgid'

    mergePkgs merged nonexistant []  = Right (reverse merged, nonexistant)
    mergePkgs merged nonexistant (next:remaining) = case next of
      InBoth (pkgid, cabalFile) (logEntry, logEntries) ->
        case newPkgInfo pkgid cabalFile logEntry logEntries users of
          Left problem  -> Left problem
          Right ok      -> mergePkgs (ok:merged) nonexistant remaining
      OnlyInLeft (pkgid, _) ->
        Left $ "Package with no upload log " ++ display pkgid
      OnlyInRight (entry,_) -> mergePkgs merged (entry:nonexistant) remaining

-- | The tarball info with the existing 'PkgInfo' records.
--
-- It's an errror to find additional tarballs, but we don't mind at the moment
-- if not all packages have a tarball, as that makes testing easier.
--
mergeTarballs :: [(PackageIdentifier, BlobStorage.BlobId)]
              -> [PkgInfo]
              -> Either String [PkgInfo]
mergeTarballs tarballInfo pkgs =
  mergePkgs [] $
    mergeBy comparingPackageId
      (sortBy (comparing fst) tarballInfo) pkgs

  where
    comparingPackageId (pkgid, _) pkginfo =
      compare pkgid (packageId pkginfo)

    mergePkgs merged []  = Right merged
    mergePkgs merged (next:remaining) = case next of
      InBoth (_, blobid) pkginfo -> mergePkgs (pkginfo':merged) remaining
         where pkginfo' = pkginfo { pkgTarball = (blobid, pkgUploadData pkginfo):pkgTarball pkginfo }
      OnlyInLeft (pkgid, _)          -> Left missing
         where missing = "Package tarball missing metadata " ++ display pkgid
      OnlyInRight            pkginfo -> mergePkgs (pkginfo:merged) remaining

mergeBy :: (a -> b -> Ordering) -> [a] -> [b] -> [MergeResult a b]
mergeBy cmp = merge
  where
    merge []     ys     = [ OnlyInRight y | y <- ys]
    merge xs     []     = [ OnlyInLeft  x | x <- xs]
    merge (x:xs) (y:ys) =
      case x `cmp` y of
        GT -> OnlyInRight   y : merge (x:xs) ys
        EQ -> InBoth      x y : merge xs     ys
        LT -> OnlyInLeft  x   : merge xs  (y:ys)

data MergeResult a b = OnlyInLeft a | InBoth a b | OnlyInRight b deriving (Show)
