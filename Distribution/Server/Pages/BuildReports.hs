-- Generate an HTML page listing all build reports for a package

module Distribution.Server.Pages.BuildReports (
  buildReportSummary,
  buildReportDetail,
  ) where

import qualified Distribution.Server.BuildReport.BuildReport as BuildReport
import Distribution.Server.BuildReport.BuildReport (BuildReport)
import Distribution.Server.BuildReport.BuildReports
import Distribution.Server.Pages.Template ( hackagePage )

import Distribution.Package
         ( PackageIdentifier )
import Distribution.PackageDescription
         ( FlagName(FlagName) )
import Distribution.Text
         ( Text, display )

import qualified Text.XHtml.Strict as XHtml
import Text.XHtml.Strict
         ( Html, (<<), (!), tr, th, td, h2
         , toHtml, table, theclass, concatHtml, isNoHtml )
import Data.List (intersperse)

buildReportSummary :: PackageIdentifier
                   -> [(BuildReportId, BuildReport)] -> XHtml.Html
buildReportSummary pkgid reports = hackagePage title body
  where
    title = display pkgid ++ ": build reports"
    body  = [h2 << title, summaryTable]

    summaryTable = XHtml.table ! [theclass "properties"] <<
                    (headerRow : dataRows)
    headerRow = tr << [ th ! [XHtml.theclass "horizontal"] <<
                          columnName
                      | columnName <- columnNames ]
    columnNames = ["Platform", "Compiler", "Build outcome"]
    dataRows =
      [ tr ! [theclass (if odd n then "odd" else "even")] <<
          [ td << (display (BuildReport.arch report)
                ++ " / "
                ++ display (BuildReport.os report))
          , td << display (BuildReport.compiler report)
          , td << detailLink reportId <<
                    display (BuildReport.installOutcome report) ]
      | (n, (reportId, report)) <- zip [(1::Int)..] reports ]
    detailLink reportId =
      XHtml.anchor ! [XHtml.href $ "/buildreports/" ++ display reportId ]

buildReportDetail :: BuildReport -> XHtml.Html
buildReportDetail report = hackagePage title [h2 << title, body]
  where
    title = display pkgid ++ ": build report"
    pkgid = BuildReport.package report
    body  = tabulate
            [ (name, value)
            | (name, field) <- showFields
            , let value = field report
            , not (isNoHtml value) ]
    
    showFields :: [(String, BuildReport -> Html)]
    showFields =
      [ ("Package",             displayHtml      . BuildReport.package)
      , ("Platform",            toHtml           . platform)
      , ("Compiler",            displayHtml      . BuildReport.compiler)
      , ("Build client",        displayHtml      . BuildReport.client)
      , ("Configuration flags", displayHtmlFlags . BuildReport.flagAssignment)
      , ("Exact dependencies",  displayHtmlList  . BuildReport.dependencies)
      , ("Install outcome",     displayHtml      . BuildReport.installOutcome)
      , ("Docs outcome",        displayHtml      . BuildReport.docsOutcome)
      ]
    platform report' = display (BuildReport.arch report')
                    ++ " / "
                    ++ display (BuildReport.os report')
    displayHtml     :: Text a => a -> Html
    displayHtml     = toHtml . display
    displayHtmlList :: Text a => [a] -> Html
    displayHtmlList  = concatHtml . intersperse (toHtml ", ") . map displayHtml
    displayHtmlFlags = concatHtml . intersperse (toHtml ", ") . map displayFlag
    displayFlag (FlagName fname, False) = toHtml $ '-':fname
    displayFlag (FlagName fname, True)  = toHtml $     fname

tabulate :: [(String, Html)] -> Html
tabulate items = table ! [theclass "properties"] <<
	[tr ! [theclass (if odd n then "odd" else "even")] <<
		[th ! [theclass "horizontal"] << t, td << d] |
		(n, (t, d)) <- zip [(1::Int)..] items]

