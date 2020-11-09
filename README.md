html-cgi
========

This package provides support for CGI programming when
the HTML library of package `html` is used.
It contains the library `HTML.CGI` which is an auxiliary library
to implement dynamic web pages with the library `HTML.Base`.

As a prerequisite to execute dynamic web pages, the installation
of the Curry Port Name Server (CPNS) and the HTML/CGI registry
provided by this package is required. This can be easily done
by the commands

    > cypm install cpns
    > cypm install html-cgi

These commands install the executables `curry-cpnsd` (CPNS demon)
and `curry-cgi` (HTML/CGI registry) in the bin directory of CPM.
These executables are invoked during the execution of a dynamic
web page.

Furthermore, one should also install the package `html` by the command

    > cypm install html

This installs the executable `curry-makecgi` which is used
to compile a dynamic web script implemented in Curry.

--------------------------------------------------------------------------

CGI Registry
------------

The CGI registry is a table of all active CGI server processes
implementing dynamic web pages. Such a process is started
when a dynamic web page is accessed on the web server.
To transmit user inputs (provided via CGI) to the corresponding
server process, the executable `curry-cgi` provided by this package
is used.

CGI server processes are automatically started and
terminated (e.g., after 120 minutes of inactivity).
In order to manage these processes manually, one can
access the CGI registry via the executable `curry-cgi`.
The following commands can be used to access CGI server processes:

    > curry-cgi show

Shows all currently active servers (name and pids)

    > curry-cgi sketch

Sketches the status of all currently active servers
(date of next cleanup and dates of all currently stored event handlers)

    > curry-cgi clean

Starts a cleanup on each server (usually, this is implicitly started
whenever a dynamic web page is requested), i.e., expired event handlers
are deleted. Morever, servers which are inactive for a long time
(the exact period is defined in HTML.cgiServerExpiration) are terminated.
Thus, it is a good idea to execute this command periodically, e.g.,
via a cron job.

    > curry-cgi stop

Stops all currently active servers (however, there are automatically
restarted when a user requests the corresponding dynamic web page)
by sending them a termination message.

    > curry-cgi kill

Kills all currently active servers by killing their processes.
This could be used instead of `stop` if some servers do not
react for some reason.

The use of stop/kill might be necessary in order to restart servers
that have required too much resources without free them (which could
be the case if the underlying run-time system does not deallocate
memory).

The package `html` contains a web script (see the README there)
which can be installed on the web server to execute these commands.
This might be necessary (instead of using `curry-cgi`) if the
web server has its own directory `/tmp` which is not accessible
from processes outside the web server.


Auxiliary files
---------------

/tmp/Curry_CGIREGISTRY : the data stored in the current registry
