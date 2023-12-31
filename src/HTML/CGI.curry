------------------------------------------------------------------------------
--- Library to support CGI programming in the HTML library.
--- It is only intended as an auxiliary library to implement dynamic web
--- pages according to the HTML library.
--- It contains a simple script that is installed for a dynamic
--- web page and which sends the user input to the real application
--- server implementing the application.
---
--- @author Michael Hanus
--- @version November 2018
------------------------------------------------------------------------------

module HTML.CGI
  ( CgiServerMsg(..), runCgiServerCmd
  , cgiServerRegistry, registerCgiServer, unregisterCgiServer
  , readCgiServerMsg, noHandlerPage, submitForm
  )
 where

import Char
import Directory ( doesFileExist, getCurrentDirectory )
import IO
import IOExts    ( exclusiveIO, connectToCommand )
import List
import ReadNumeric
import ReadShowTerm
import System
import Time

import HTML.CGI.Config
import Network.NamedSocket
import Network.CPNS ( unregisterPort )

--------------------------------------------------------------------------
-- Should the log messages of the server stored in a log file?
withCgiLogging :: Bool
withCgiLogging = True

--------------------------------------------------------------------------
--- The messages to comunicate between the cgi script and the server program.
--- CgiSubmit env cgienv nextpage - pass the environment and show next page,
---   where env are the values of the environment variables of the web script
---   (e.g., QUERY_STRING, REMOTE_HOST, REMOTE_ADDR),
---   cgienv are the values in the current form submitted by the client,
---   and nextpage is the answer text to be shown in the next web page
--- @cons GetLoad - get info about the current load of the server process
--- @cons SketchStatus - get a sketch of the status of the server
--- @cons SketchHandlers - get a sketch of all event handlers of the server
--- @cons ShowStatus - show the status of the server with all event handlers
--- @cons CleanServer - clean up the server (with possible termination)
--- @cons StopCgiServer - stop the server
data CgiServerMsg = CgiSubmit [(String,String)] [(String,String)]
                  | GetLoad
                  | SketchStatus
                  | SketchHandlers
                  | ShowStatus
                  | CleanServer
                  | StopCgiServer

--- Reads a line from a handle and check whether it is a syntactically
--- correct cgi server message.
readCgiServerMsg :: Handle -> IO (Maybe CgiServerMsg)
readCgiServerMsg handle = do
  line <- hGetLine handle
  case readsQTerm line of
     [(msg,rem)] -> return (if all isSpace rem then Just msg else Nothing)
     _ -> return Nothing

--------------------------------------------------------------------------
-- Main program to start a cgi script. It uses the given arguments
-- to starts a small script to forward the arguments to a cgi server process.
--
-- Optional script arguments:
-- "-servertimeout n": The timeout period for the cgi server in milliseconds.
--                     If the cgi server process does not receive any request
--                     during this period, it will be terminated.
--                     The default value is defined in the library HTML.
--
-- "-loadbalance <t>": specifies kind of load balancing (see makecurrycgi)
--                     Current possible values for <t>:
--                     "no|standard|multiple"
submitForm :: [String] -> IO ()
submitForm sargs = do
  let (serverargs,lb,rargs) = stripServerArgs "" NoBalance sargs
  case rargs of
    [url,cgikey,serverprog] -> cgiScript url serverargs lb
                                         (cgikey2portname cgikey) serverprog
    [portname] -> cgiInteractiveScript portname -- for interactive execution
    _ -> putStrLn $ "ERROR: cgi script called with illegal arguments!"
 where
  stripServerArgs serverargs load args = case args of
    ("-servertimeout":tos:rargs) ->
         stripServerArgs (" -servertimeout "++tos) load rargs
    ("-multipleservers":rargs) -> stripServerArgs serverargs Multiple rargs
    ("-loadbalance":lbt:rargs) ->
      stripServerArgs serverargs
                      (if lbt=="no" then NoBalance else
                       if lbt=="multiple" then Multiple else Standard) rargs
    _ -> (serverargs,load,args)

-- load balance types:
data LoadBalance = NoBalance | Standard | Multiple
 deriving Eq

--- Executes a specific command for a cgi server and returns the command output.
runCgiServerCmd :: String -> CgiServerMsg -> IO String
runCgiServerCmd portname cmd = case cmd of
  StopCgiServer -> do
    h <- trySendScriptServerMessage portname StopCgiServer
    hClose h
    unregisterPort portname
    return $ "Server at port '" ++ portname ++ "' unregistered."
  CleanServer -> do
    h <- trySendScriptServerMessage portname CleanServer
    hGetContents h
  GetLoad -> do
    h <- trySendScriptServerMessage portname GetLoad
    hGetContents h
  ShowStatus -> do
    h <- trySendScriptServerMessage portname ShowStatus
    getInputAndClose h
  SketchStatus -> do
    h <- trySendScriptServerMessage portname SketchStatus
    getInputAndClose h
  SketchHandlers -> do
    h <- trySendScriptServerMessage portname SketchHandlers
    getInputAndClose h
  _ -> error "HtmlCgi.runCgiServerCmd: called with illegal command!"

--- Translates a cgi progname and key into a name for a port:
cgikey2portname :: String -> String
cgikey2portname cgikey =
  concatMap (\c->if isAlphaNum c then [c] else []) cgikey

-- Forward user inputs for interactive execution of cgi scripts:
cgiInteractiveScript :: String -> IO ()
cgiInteractiveScript portname = do
  cgiServerEnvVals <- mapIO getEnviron cgiServerEnvVars
  let cgiServerEnv = zip cgiServerEnvVars cgiServerEnvVals
  formEnv <- getFormVariables
  catch (sendToServerAndPrintOrFail cgiServerEnv formEnv)
        (putStrLn . errorPage)
 where
  sendToServerAndPrintOrFail cgiEnviron newcenv = do
    h <- trySendScriptServerMessage portname (CgiSubmit cgiEnviron newcenv)
    copyOutputAndClose h

  errorPage e =
    "Content-type: text/html\n\n" ++
    "<html>\n<head><title>Server Error</title></head>\n" ++
    "<body>\n<h1>Server Error</h1>\n" ++ showError e ++ "</body>\n</html>"


-- Forward user inputs to cgi server process:
cgiScript :: String -> String -> LoadBalance -> String -> String -> IO ()
cgiScript url serverargs loadbalance portname serverprog = do
  cgiServerEnvVals <- mapIO getEnviron cgiServerEnvVars
  let cgiServerEnv = zip cgiServerEnvVars cgiServerEnvVals
  let urlparam = head cgiServerEnvVals
  formEnv <- getFormVariables
  if null formEnv
   then do -- call to initial script
     scriptKey <- if loadbalance==Multiple then getFreshKey
                                           else return ""
     catch (submitToServerOrStart url serverargs loadbalance portname
                                      scriptKey serverprog cgiServerEnv)
           (\_ -> putStrLn (noHandlerPage url urlparam))
   else do -- call to continuation script
     let scriptKey = maybe "" id (lookup "SCRIPTKEY" formEnv)
         cgiEnviron = ("SCRIPTKEY",scriptKey) : cgiServerEnv
         newcenv = filter (\e -> fst e /= "SCRIPTKEY") formEnv
     catch (sendToServerAndPrintOrFail scriptKey cgiEnviron newcenv)
           (\_ -> putStrLn (noHandlerPage url urlparam))
 where
  sendToServerAndPrintOrFail scriptKey cgiEnviron newcenv = do
    h <- trySendScriptServerMessage (portname++scriptKey) 
                                    (CgiSubmit cgiEnviron newcenv)
    eof <- hIsEOF h
    if eof then error "Html.cgiScript: unexpected EOF failure"
           else copyOutputAndClose h

-- get a new unique key for a script:
getFreshKey :: IO String
getFreshKey = do
  ctime <- getClockTime
  pid <- getPID
  return (show (clockTimeToInt ctime) ++ '_' : show pid)


------------------------------------------------------------------------
-- Generate HTML string of a web page with "no handler" error:
noHandlerPage :: String -> String -> String
noHandlerPage cgiurl urlparam =
 "Content-type: text/html\n\n" ++
 "<html>\n<head><title>Server Error</title></head>\n" ++
 "<body>\n<h1>Error: no submission handler</h1>\n" ++
 "<p>Your request cannot be processed due to one of the following reasons:</p>\n" ++
 "<ul>\n" ++
 "<li>You have not submitted the web form for a long period (timeout).</li>\n"++
 "<li>You have used the 'back' button of your browser and submitted\n"++
 "  the web form again (which should not be done in order to avoid the\n"++
 "  double submission of data).</li>\n" ++
 "<li>The web server has been rebooted.</li>\n" ++
 "</ul>\n" ++
 "<p>In any case, <a href=\"" ++
   (cgiurl ++ if null urlparam then "" else '?':urlparam) ++
 "\">please click here to restart.</a></p>\n" ++
 "</body>\n</html>"

------------------------------------------------------------------------
--- The values of the environment variables of the web script server
--- that are transmitted to the application program.
--- Currently, it contains only a selection of all reasonable variables
--- but this list can be easily extended.
cgiServerEnvVars :: [String]
cgiServerEnvVars =
  ["PATH_INFO","QUERY_STRING","HTTP_COOKIE","REMOTE_HOST","REMOTE_ADDR",
   "REQUEST_METHOD","SCRIPT_NAME","SERVER_NAME","SERVER_PORT"]

-- send a message to the script server and return the connection handle,
-- or fail:
trySendScriptServerMessage :: String -> a -> IO Handle
trySendScriptServerMessage portname msg =
  connectToSocketRepeat scriptServerTimeOut done 0 (portname++"@localhost") >>=
  maybe failed (\h -> hPutStrLn h (showQTerm msg) >> hFlush h >> return h)

-- submit an initial web page request to a server or restart it:
submitToServerOrStart :: String -> String -> LoadBalance -> String -> String
                      -> String -> [(String,String)] -> IO ()
submitToServerOrStart url serverargs loadbalance pname scriptkey
                      serverprog cgiServerEnv =
   connectToSocketRepeat scriptServerTimeOut done 0 completeportname >>=
   maybe (execAndCopyOutput servercmd)
         (\h ->
           if loadbalance/=Standard
             then cgiSubmit h
             else do
              isbusy <- getLoadOfServer h
              if isbusy
                then submitToOtherServer
                else connectToSocketRepeat scriptServerTimeOut done 0
                                           completeportname >>=
                     maybe (execAndCopyOutput servercmd) cgiSubmit )
 where
  completeportname = pname++scriptkey++"@localhost"
  cmd = serverprog ++ serverargs ++ " -port \"" ++ pname
                   ++ "\" -scriptkey \"" ++ scriptkey ++ "\""
  errout = if withCgiLogging then " 2>> "++url++".log" else ""
  servercmd = cmd++errout++" &"

  cgiSubmit h = do
    let cgiEnviron = ("SCRIPTKEY",scriptkey) : cgiServerEnv
    hPutStrLn h (showQTerm (CgiSubmit cgiEnviron []))
    hFlush h
    copyOutputAndClose h

  getLoadOfServer h = do
    hPutStrLn h (showQTerm GetLoad)
    hFlush h
    loadanswer <- hGetLine h
    hClose h
    return (take 4 loadanswer == "busy")

  submitToOtherServer = do
    other <- findOtherReadyServer
    otherscriptkey <- maybe (getFreshKey >>= \k -> return (scriptkey++k))
                            return
                            other
    submitToServerOrStart url serverargs loadbalance pname
                          otherscriptkey serverprog cgiServerEnv

  -- try to return the scriptkey of another ready server
  findOtherReadyServer = do
    regs <- readCgiServerRegistry
    let otherports = map (\ (_,_,p)->p)
                         (filter (\ (_,prog,_) -> serverprog==prog) regs)
    findOtherReadyServerInPorts otherports

  findOtherReadyServerInPorts [] = return Nothing
  findOtherReadyServerInPorts (p:ps) = do
    let (ppname,pscriptkey) = splitAt (length pname) p
    if ppname==pname -- it is a port for the current script version
     then connectToSocketRepeat scriptServerTimeOut done 0 (p++"@localhost") >>=
          maybe (findOtherReadyServerInPorts ps) -- no connection
                (\h -> do
                   isbusy <- getLoadOfServer h
                   if isbusy
                    then findOtherReadyServerInPorts ps
                    else return (Just pscriptkey) )
     else findOtherReadyServerInPorts ps

-- Execute a command and copy its output to stdout.
-- This is necessary since some web servers do not transfer
-- the output of cgi programs if the process is not terminated.
execAndCopyOutput :: String -> IO ()
execAndCopyOutput cmd = connectToCommand cmd >>= copyOutputAndClose

-- Copy input from the given handle to stdout and close it after eof.
copyOutputAndClose :: Handle -> IO ()
copyOutputAndClose h = do
  clen <- copyUntilEmptyLine 0
  if clen==0 then copyOutputUntilEOF else copyOutputLength clen
  hClose h
 where
  copyUntilEmptyLine clen = do
    l <- hGetLine h
    putStrLn l
    let clen' = if "Content-Length:" `isPrefixOf` l
                then maybe clen fst (readNat (drop 15 l))
                else clen
    if null l then return clen' else copyUntilEmptyLine clen'

  copyOutputUntilEOF = do
    eof <- hIsEOF h
    if eof
     then done
     else hGetLine h >>= putStrLn >> copyOutputUntilEOF

  copyOutputLength n = do
    if n>0 then hGetChar h >>= putChar >> copyOutputLength (n-1)
           else done

-- Gets input from the given handle and close it after eof.
getInputAndClose :: Handle -> IO String
getInputAndClose h = do
  (clen,s) <- getUntilEmptyLine 0
  cs <- if clen==0 then getInputUntilEOF else getInputLength clen
  hClose h
  return (s ++ cs)
 where
  getUntilEmptyLine clen = do
    l <- hGetLine h
    let clen' = if "Content-Length:" `isPrefixOf` l
                  then maybe clen fst (readNat (drop 15 l))
                  else clen
    if null l then return (clen',l)
              else do (clen'',s) <- getUntilEmptyLine clen'
                      return (clen'', l ++ '\n' : s)

  getInputUntilEOF = do
    eof <- hIsEOF h
    if eof
     then return ""
     else do ln <- hGetLine h
             cs <- getInputUntilEOF
             return (ln ++ '\n' : cs)

  getInputLength n = do
    if n>0 then do c  <- hGetChar h
                   cs <- getInputLength (n-1)
                   return (c:cs)
           else return ""

-- Puts a line to stderr:
putErrLn :: String -> IO ()
putErrLn s = hPutStrLn stderr s >> hFlush stderr

------------------------------------------------------------------------------
--- Gets the list of variable/value pairs sent from the browser for the
--- current CGI script.
--- Used for the implementation of the HTML event handlers.
getFormVariables :: IO [(String,String)]
getFormVariables = do
  clen <- getEnviron "CONTENT_LENGTH"
  cont <- getNChar (maybe 0 fst (readNat clen))
  return (includeCoordinates (parseCgiEnv cont))

-- translate a string of cgi environment bindings into list of binding pairs:
parseCgiEnv :: String -> [(String,String)]
parseCgiEnv s | s == ""   = []
              | otherwise = map ufield2field
                             (map (\(n,v)->(n,utf2latin (urlencoded2string v)))
                                  (map (splitChar '=') (split (=='&') s)))
 where
   ufield2field (n,v) = if take 7 n == "UFIELD_"
                        then (tail n, utf2latin (urlencoded2string v))
                        else (n,v)

   -- split a string at particular character:
   splitChar c xs = let (ys,zs) = break (==c) xs
                    in if zs==[] then (ys,zs) else (ys,tail zs)

   -- split a string at all positions of a particular character:
   split p xs =
    let (ys,zs) = break p xs
    in if zs==[] then [ys]
                 else ys : split p (tail zs)

--- Translates urlencoded string into equivalent ASCII string.
urlencoded2string :: String -> String
urlencoded2string [] = []
urlencoded2string (c:cs)
  | c == '+'  = ' ' : urlencoded2string cs
  | c == '%'  = chr (maybe 0 fst (readHex (take 2 cs)))
                 : urlencoded2string (drop 2 cs)
  | otherwise = c : urlencoded2string cs

--- Transforms a string with UTF-8 umlauts into a string with latin1 umlauts.
utf2latin :: String -> String
utf2latin [] = []
utf2latin [c] = [c]
utf2latin (c1:c2:cs)
 | ord c1 == 195 = chr (ord c2 + 64) : utf2latin cs
 | otherwise     = c1 : utf2latin (c2:cs)

includeCoordinates :: [(String,String)] -> [(String,String)]
includeCoordinates [] = []
includeCoordinates ((tag,val):cenv) 
  = case break (=='.') tag of
      (_,[]) -> (tag,val):includeCoordinates cenv
      (event,['.','x']) -> ("x",val):(event,val):includeCoordinates cenv
      (_,['.','y']) -> ("y",val):includeCoordinates cenv
      _ -> error "includeCoordinates: unexpected . in url parameter"
   

-- get n chars from stdin:
getNChar :: Int -> IO String
getNChar n = if n<=0 then return ""
                     else do c <- getChar
                             cs <- getNChar (n-1)
                             return (c:cs)

------------------------------------------------------------------------------
-- Register a new cgi server process (for global management of all such
-- processes on a host):
registerCgiServer :: String -> String -> IO ()
registerCgiServer eurl epname = do
  registryfile <- cgiServerRegistry
  -- we want to be sure that everything is evaluated before locking:
  ((register $## registryfile) $## eurl) $## epname
 where
  register registryfile url pname = exclusiveIO (registryfile ++ ".lock") $ do
    exreg <- doesFileExist registryfile
    unless exreg $ do
      writeFile registryfile ""
      system ("chmod 666 " ++ registryfile) >> done
    pid <- getPID
    wd <- getCurrentDirectory
    appendFile registryfile (show (pid,wd++"/"++url++".server",pname) ++ "\n")

-- Unregister the previously registered cgi server process:
-- processes on a host):
unregisterCgiServer :: String -> IO ()
unregisterCgiServer epname = do
  registryfile <- cgiServerRegistry
  -- we want to be sure that everything is evaluated before locking:
  (unregister $## registryfile) $## epname
 where
  unregister registryfile pname = exclusiveIO (registryfile ++ ".lock") $ do
    exreg <- doesFileExist registryfile
    if not exreg then done else do
      mypid <- getPID
      regs <- readCgiServerRegistry
      let uregs = filter (\ (pid,_,port) -> mypid/=pid || pname/=port) regs
      writeFile registryfile (concatMap (\reg -> show reg ++ "\n") uregs)

-- Return the current server registry:
readCgiServerRegistry :: IO [(Int,String,String)]
readCgiServerRegistry = do
  registryfile <- cgiServerRegistry
  regs <- readQTermListFile registryfile
  seq (length regs) done -- just to be sure that everything is immediately read
  return regs

---------------------------------------------------------------------------
