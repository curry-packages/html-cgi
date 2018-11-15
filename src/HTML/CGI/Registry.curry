------------------------------------------------------------------------
--- A simple command-based manager for CGI servers.
--- 
--- @author Michael Hanus
--- @version November 2018
------------------------------------------------------------------------

module HTML.CGI.Registry
 where

import Directory    ( doesFileExist )
import IOExts
import ReadShowTerm
import System

import HTML.CGI
import HTML.CGI.Config ( cgiServerRegistry )

main :: IO ()
main = do
  args <- getArgs
  case args of
    []           -> showUsage
    ["show"]     -> showAllActiveServers >>= putStrLn
    ["load"]     -> cmdForAllServers "Status of " GetLoad      >>= putStrLn
    ["status"]   -> cmdForAllServers "Status of " SketchStatus >>= putStrLn
    ["sketch" ]  -> cmdForAllServers "Sketch status of " SketchHandlers
                                                                    >>= putStrLn
    ["showall"]  -> cmdForAllServers "Status of "        ShowStatus >>= putStrLn
    ["clean"]    -> do out <- cmdForAllServers "Clean status of " CleanServer
                       getAndCleanRegistry
                       putStrLn out
    ["stop"]     -> do out <- cmdForAllServers "Stop cgi server " StopCgiServer
                       getAndCleanRegistry
                       putStrLn out
    ["kill"]     -> killAllActiveServers >>= putStrLn
    ["stopscript",scriptprog] -> stopActiveScriptServers scriptprog >>= putStrLn
    ("submit" : margs)        -> submitForm margs
    _                         -> error "Illegal arguments!"

showUsage :: IO ()
showUsage = putStrLn $ unlines $ registryCommands ++ ["", submitParams]
 where
  submitParams = "submit <url> <cgikey> <serverprog> : submit dynmic web page"

registryCommands :: [String]
registryCommands =
  [ "Registry commands:"
  , "show    : show all currently active servers"
  , "load    : show load of all currently active servers"
  , "status  : show status of all currently active servers"
  , "sketch  : sketches status of all currently active servers"
  , "showall : show status of the server with all event handlers"
  , "clean   : starts cleanup on each server"
  , "stop    : stop all currently active servers"
  , "kill    : kill all currently active servers"
  , "stopscript <script> : stop all active servers for a cgi script"
  ]

showAllActiveServers :: IO String
showAllActiveServers = do
  let header = "Currently active cgi script servers:"
      line   = take (length header) (repeat '=')
  result <- doForAllServers "" (\_ -> return "")
  return (unlines [header, line, result])

killAllActiveServers :: IO String
killAllActiveServers = do
  result <- doForAllServers "Killing process of cgi server "
              (\ (pid,_,_) -> system ("kill -9 " ++ show pid) >> return "")
  getAndCleanRegistry
  return (unlines [result, "All active servers killed!"])

--- Stops the active servers for a particular cgi script by sending them
--- a stop message. This operation is used by the installation script
--- "makecurrycgi" to terminate old versions of a server.
stopActiveScriptServers :: String -> IO String
stopActiveScriptServers scriptprog = do
  regs <- getAndCleanRegistry
  let header = "Stop active servers for cgi script: " ++ scriptprog
  stopmsgs <- mapIO stopServer regs
  return (unlines (header : stopmsgs))
 where
  stopServer (_,progname,port) =
    if progname == scriptprog
      then runCgiServerCmd port StopCgiServer
      else return ""

doForAllServers :: String -> ((Int,String,String) -> IO String) -> IO String
doForAllServers cmt action = do
  regs <- getAndCleanRegistry
  mapIO doForServer regs >>= return . unlines
 where
  doForServer (pid,progname,port) = do
    let title = cmt ++ progname++":\n(pid: "++show pid++", port: "++port++")\n"
    catch (action (pid,progname,port) >>= \s -> return (title ++ s))
          (\_ -> return title)

cmdForAllServers :: String -> CgiServerMsg -> IO String
cmdForAllServers cmt servercmd =
  doForAllServers
    cmt
    (\ (_,_,port) -> catch (runCgiServerCmd port servercmd)
                           (\_ -> return ""))

-- Get the registry with active processes and clean up the registry file.
getAndCleanRegistry :: IO [(Int,String,String)]
getAndCleanRegistry = do
  registryfile <- cgiServerRegistry
  exclusiveIO (registryfile ++ ".lock") $ do
    regexists <- doesFileExist registryfile
    regs <- if regexists then readQTermListFile registryfile
                         else return []
    aregs <- mapIO (\ (pid,pname,port) -> doesProcessExist pid >>= \pidruns ->
                     return (if pidruns then [(pid,pname,port)] else [])) regs
    let cregs = concat aregs
    when (cregs/=regs) $
      writeFile registryfile (concatMap (\reg -> show reg ++ "\n") cregs)
    return cregs

-- Tests whether a process with a given pid is running.
doesProcessExist :: Int -> IO Bool
doesProcessExist pid = do
  status <- system("test -z \"`ps -p "++show pid++" | fgrep "++show pid++"`\"")
  return (status>0)
