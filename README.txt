README for "sockptyr"
23 Nov 2019

"sockptyr" is a program that connects/accept connections to Unix domain
sockets, on Linux and similar systems, and allows programs to be run
on them.

I mainly intend to use it with my VirtualBox virtual consoles.  This
was a hobby project and has no warranty; use at your own risk.

prerequisites:
    make, C compiler, Tcl/Tk interpreter "wish".  Nothing unusual.
compile:
    make -f Makefile.linux
configure:
    Edit sockptyr_gui.tcl where there are a bunch of "set config(...)"
    lines.  Comments in the code give some idea how.
run:
    wish sockptyr_gui.tcl
use:
    A list on the left of the GUI window will show connections.  Click
    on them to see details on the right side of the GUI window.  It will
    have buttons (depending on configuration and connection status) for
    doing things like starting up a terminal window connected to it.
alternate use:
    "sockptyr" includes a library of Tcl commands to perform its tasks
    such as accepting connections, linking them together, etc.  It also
    contains an interface to "inotify" on Linux.  See the document
    "sockptyr-tcl-api.txt" for usage.
