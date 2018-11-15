------------------------------------------------------------------------------
--- This module contains some configuration definitions for
--- CGI programming support in the HTML library.
---
--- @author Michael Hanus
--- @version November 2018
------------------------------------------------------------------------------

module HTML.CGI.Config
  ( scriptServerTimeOut, cgiServerRegistry )
 where

import Directory ( getTemporaryDirectory )
import FilePath  ( (</>) )

-- The timeout (in msec) of the script server.
-- If the port of the application server is not available within the timeout
-- period, we assume that the application server does not exist and we start
-- a new one.
scriptServerTimeOut :: Int
scriptServerTimeOut = 1000

--- The name of the file where registration information for all cgi servers
--- is kept.
--- The registration is used to get an overview on all cgi servers on
--- a machine or to send requests (e.g., cleanup) to all cgi servers.
cgiServerRegistry :: IO String
cgiServerRegistry = do
  tmp <- getTemporaryDirectory
  return $ tmp </> "Curry_CGIREGISTRY"

