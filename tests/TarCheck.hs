import Distribution.Server.Upload (unpackPackage)
import qualified Data.ByteString.Lazy as BS
import qualified Codec.Compression.GZip as GZip

import System.Environment (getArgs)
import System.FilePath (takeFileName)

main = do
  files <- getArgs
  sequence_
    [ do tar <- BS.readFile file
         case unpackPackage (takeFileName file) (GZip.decompress tar) of
           Left err -> do
             putStrLn $ "FAILED! " ++ takeFileName file
             putStr   $ err ++ "\n\n"
           Right (pkg, []) -> return ()
           Right (pkg, warnings) -> do
             putStrLn $ "Warnings " ++ takeFileName file
             putStrLn (unlines warnings)
    | file <- files ]
