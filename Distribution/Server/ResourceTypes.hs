{-# LANGUAGE GeneralizedNewtypeDeriving, DeriveDataTypeable, StandaloneDeriving #-}
{-# OPTIONS_GHC -fno-warn-orphans #-}
-----------------------------------------------------------------------------
-- |
-- Module      :  Distribution.Server.ResourceTypes
-- Copyright   :  (c) David Himmelstrup 2008
--                    Duncan Coutts 2008
-- License     :  BSD-like
--
-- Maintainer  :  duncan@haskell.org
-- Stability   :  provisional
-- Portability :  portable
--
-- Types for various kinds of resources we serve, xml, package tarballs etc.
-----------------------------------------------------------------------------
module Distribution.Server.ResourceTypes where

import Distribution.Server.BlobStorage
         ( BlobId )

import HAppS.Server
         ( ToMessage(..), Response(..), RsFlags(..), nullRsFlags, mkHeaders )

import qualified Data.ByteString.Char8 as BS
import qualified Data.ByteString.Lazy.Char8 as BS.Lazy
import Text.RSS
         ( RSS )
import qualified Text.RSS as RSS
         ( rssToXML, showXML )
import Data.Time.Clock
         ( UTCTime )
import qualified Data.Time.Format as Time
         ( formatTime )
import System.Locale
         ( defaultTimeLocale )

data IndexTarball = IndexTarball BS.Lazy.ByteString

instance ToMessage IndexTarball where
  toContentType _ = BS.pack "application/gzip"
  toMessage (IndexTarball bs) = bs


data PackageTarball = PackageTarball BS.Lazy.ByteString BlobId UTCTime

instance ToMessage PackageTarball where
  toResponse (PackageTarball bs blobid time) = mkResponse bs
    [ ("Content-Type",  "application/gzip")
    , ("Content-MD5",   show blobid)
    , ("ETag",          '"' : show blobid ++ ['"'])
    , ("Last-modified", formatTime time)
    ]

formatTime :: UTCTime -> String
formatTime = Time.formatTime defaultTimeLocale rfc822DateFormat
  where
    -- HACK! we're using UTC but http requires GMT
    -- hopefully it's ok to just say it's GMT
    rfc822DateFormat = "%a, %d %b %Y %H:%M:%S GMT"

newtype CabalFile = CabalFile BS.Lazy.ByteString

instance ToMessage CabalFile where
    toContentType _ = BS.pack "text/plain"
    toMessage (CabalFile bs) = bs

newtype BuildLog = BuildLog BS.Lazy.ByteString

instance ToMessage BuildLog where
    toContentType _ = BS.pack "text/plain"
    toMessage (BuildLog bs) = bs

instance ToMessage RSS where
    toContentType _ = BS.pack "application/rss+xml"
    toMessage = BS.Lazy.pack . RSS.showXML . RSS.rssToXML


mkResponse :: BS.Lazy.ByteString -> [(String, String)] -> Response
mkResponse bs headers = Response {
    rsCode    = 200,
    rsHeaders = mkHeaders headers,
    rsFlags   = nullRsFlags,
    rsBody    = bs
  }

mkResponseLen :: BS.Lazy.ByteString -> Int -> [(String, String)] -> Response
mkResponseLen bs len headers = Response {
    rsCode    = 200,
    rsHeaders = mkHeaders (("Content-Length", show len) : headers),
    rsFlags   = nullRsFlags { rsfContentLength = False },
    rsBody    = bs
  }
