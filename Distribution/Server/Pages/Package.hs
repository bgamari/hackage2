-- Body of the HTML page for a package
module Distribution.Server.Pages.Package (
    packagePage,
    renderDependencies,
    renderVersion,
    renderFields,
    renderDownloads
  ) where

import Distribution.Server.Features.Packages
import Distribution.Server.Packages.Preferred

import Distribution.Server.Pages.Package.HaddockParse (parseHaddockParagraphs)
import Distribution.Server.Pages.Package.HaddockLex  (tokenise)
import Distribution.Server.Pages.Package.HaddockHtml
import Distribution.Server.Packages.ModuleForest

import Distribution.Package
import Distribution.PackageDescription as P
import Distribution.Version (Version (..), VersionRange (..))
import Distribution.Text        (display)
import Text.XHtml.Strict hiding (p, name)

import Data.Maybe               (maybeToList)
import Data.List                (intersperse, intercalate)
import System.FilePath.Posix    ((</>), (<.>))
import System.Locale            (defaultTimeLocale)
import Data.Time.Format         (formatTime)

packagePage :: PackageRender -> [Html] -> [Html] -> [(String, Html)] -> [(String, Html)] -> Maybe URL -> [Html]
packagePage render headLinks top sections bottom docURL =
    [h2 << docTitle]
  ++ renderHeads
  ++ top
  ++ pkgBody render sections
  ++ concatMap (\(s, p) -> [h3 << s, p])
     (maybeToList (moduleSection render docURL) ++ [downloadSection render] ++ bottom)
  where
    pkgid = rendPkgId render
    docTitle = display (packageName pkgid) ++ case synopsis (rendOther render) of
        "" -> ""
        short  -> ": " ++ short
    renderHeads = case headLinks of
        [] -> []
        items -> [thediv ! [thestyle "font-size: small"] <<
            (map (\item -> "[" +++ item +++ "] ") items)]
    cabalLink = anchor ! [href cabalHomeURL] <<
                (image ! [alt "Built with Cabal", src cabalLogoURL])


-- | Body of the package page
pkgBody :: PackageRender -> [(String, Html)] -> [Html]
pkgBody render sections =
    prologue (description $ rendOther render) ++
    propertySection sections

prologue :: String -> [Html]
prologue [] = []
prologue desc = case parseHaddockParagraphs (tokenise desc) of
    Left _ -> [paragraph << p | p <- paragraphs desc]
    Right doc -> [markup htmlMarkup doc]

-- Break text into paragraphs (separated by blank lines)
paragraphs :: String -> [String]
paragraphs = map unlines . paras . lines
  where paras xs = case dropWhile null xs of
                [] -> []
                xs' -> case break null xs' of
                        (para, xs'') -> para : paras xs''

downloadSection :: PackageRender -> (String, Html)
downloadSection render = ("Downloads", ulist << map (li <<) downloadItems)
  where downloadItems =
            [if tarExists then [anchor ! [href downloadURL] << (display pkgId ++ ".tar.gz"),
                                toHtml << " (Cabal source package)"]
                          else [toHtml << "Package tarball not uploaded"],
             [anchor ! [href cabalURL] << "Package description",
             toHtml $ if tarExists then " (included in the package)" else ""]]
        downloadURL = packageFile pkgId
        cabalURL = cabalFile pkgId
        tarExists = rendHasTarball render
        pkgId = rendPkgId render

moduleSection :: PackageRender -> Maybe URL -> Maybe (String, Html)
moduleSection render docURL = fmap msect (rendModules render)
  where msect lib = ("Modules", renderModuleForest docURL lib)

propertySection :: [(String, Html)] -> [Html]
propertySection sections = return . tabulate $ filter (not . isNoHtml . snd) sections

tabulate :: [(String, Html)] -> Html
-- tabulate items = dlist << concat [[dterm << t, ddef << d] | (t, d) <- items]
tabulate items = table ! [theclass "properties"] <<
        [tr ! [theclass (if odd n then "odd" else "even")] <<
                [th ! [theclass "horizontal"] << t, td << d] |
                (n, (t, d)) <- zip [(1::Int)..] items]

renderDependencies :: PackageRender -> (String, Html)
renderDependencies render = ("Dependencies", case htmlDepsList of
    [] -> toHtml "None"
    _  -> foldr (+++) noHtml htmlDepsList)
  where htmlDepsList = 
            intersperse (toHtml " " +++ bold (toHtml "or") +++ br) $
            map showDependencies (rendDepends render)

showDependencies :: [Dependency] -> Html
showDependencies deps = commaList (map showDependency deps)

showDependency ::  Dependency -> Html
showDependency (Dependency (PackageName pname) vs) = showPkg +++ showVersion vs
  where showVersion AnyVersion = noHtml
        showVersion vs' = toHtml (" (" ++ display vs' ++ ")")
        -- mb_vers links to latest version in range. This is a bit computationally
        -- expensive, not cache-friendly, and perhaps unexpected in some cases
        {-mb_vers = maybeLast $ filter (`withinRange` vs) $ map packageVersion $
                    PackageIndex.lookupPackageName vmap (PackageName pname)-}
        -- nonetheless, we should ensure that the package exists /before/
        -- passing along the PackageRender, which is not the case here
        showPkg = anchor ! [href . packageURL $ PackageIdentifier (PackageName pname) (Version [] [])] << pname

renderVersion :: PackageId -> [(Version, VersionStatus)] -> Maybe String -> (String, Html)
renderVersion (PackageIdentifier pname pversion) allVersions info =
    (if null earlierVersions && null laterVersions then "Version" else "Versions", versionList +++ infoHtml)
  where (earlierVersions, laterVersionsInc) = span ((<pversion) . fst) allVersions
        (thisVersion, laterVersions) = case laterVersionsInc of
            (v:later) | fst v == pversion -> (Just v, later)
            later -> (Nothing, later)
        versionList = commaList $ map versionedLink earlierVersions
                               ++ (case pversion of
                                      Version [] [] -> []
                                      _ -> [strong ! (maybe [] (status . snd) thisVersion) << display pversion]
                                  )
                               ++ map versionedLink laterVersions
        versionedLink (v, s) = anchor ! (status s ++ [href $ packageURL $ PackageIdentifier pname v]) << display v
        status st = case st of
            NormalVersion -> []
            DeprecatedVersion  -> [theclass "deprecated"]
            UnpreferredVersion -> [theclass "unpreferred"]
        infoHtml = case info of Nothing -> noHtml; Just str -> " (" +++ (anchor ! [href str] << "info") +++ ")"

renderDownloads :: Int -> Int -> Version -> (String, Html)
renderDownloads totalDown versionDown version =
    ("Downloads", toHtml $ show versionDown ++ " for " ++ display version ++
                      " and " ++ show totalDown ++ " total")

renderFields :: PackageRender -> [(String, Html)]
renderFields render = [
        -- Cabal-Version
        ("License",     toHtml $ rendLicenseName render),
        ("Copyright",   toHtml $ P.copyright desc),
        ("Author",      toHtml $ author desc),
        ("Maintainer",  maintainField $ rendMaintainer render),
        ("Stability",   toHtml $ stability desc),
        ("Category",    commaList . map toHtml $ rendCategory render), 
        ("Home page",   linkField $ homepage desc),
        ("Bug tracker", linkField $ bugReports desc),
        ("Executables", commaList . map toHtml $ rendExecNames render),
        ("Upload date", toHtml $ showTime utime),
        ("Uploaded by", toHtml $ uname)
      ]
  where desc = rendOther render
        (utime, uname) = rendUploadInfo render
        linkField url = case url of
            [] -> noHtml
            _  -> anchor ! [href url] << url
        maintainField mnt = case mnt of
            Nothing -> strong ! [theclass "warning"] << toHtml "none"
            Just n  -> toHtml n
        showTime = formatTime defaultTimeLocale "%c"

commaList :: [Html] -> Html
commaList = concatHtml . intersperse (toHtml ", ")
-----------------------------------------------------------------------------

renderModuleForest :: Maybe URL -> ModuleForest -> Html
renderModuleForest mb_url = renderForest []
    where
      renderForest _       [] = noHtml
      renderForest pathRev ts = myUnordList $ map renderTree ts
          where
            renderTree (Node s isModule subs) =
                    ( if isModule then moduleEntry newPath else italics << s )
                +++ renderForest newPathRev subs
                where
                  newPathRev = s:pathRev
                  newPath = reverse newPathRev

      moduleEntry = maybe modName linkedName mb_url
      modName path = toHtml (intercalate "." path)
      linkedName url path = anchor ! [href modUrl] << modName path
          where
            modUrl = url ++ "/" ++ intercalate "-" path ++ ".html"
      myUnordList :: HTML a => [a] -> Html
      myUnordList = unordList ! [theclass "modules"]

------------------------------------------------------------------------------
-- TODO: most of these should be available from the CoreFeature
-- so pass it in to this module

-- | URL describing a package.
packageURL :: PackageIdentifier -> URL
packageURL pkgId = "/package" </> display pkgId

-- | The name of the package file for a given package identifier
packageFile :: PackageIdentifier -> URL
packageFile pkgId = "/package" </> display pkgId </> display pkgId <.> "tar.gz"

-- | The name of the Cabal file for a given package identifier
cabalFile :: PackageIdentifier -> URL
cabalFile pkgId = packageURL pkgId </> display (pkgName pkgId) <.> "cabal"

cabalLogoURL :: URL
cabalLogoURL = "/built-with-cabal.png"

-- global URLs
cabalHomeURL :: URL
cabalHomeURL = "http://haskell.org/cabal/"
