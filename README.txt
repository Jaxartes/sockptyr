documentation for "sockptyr"
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
    Copy sockptyr.cfg.example to sockptyr.cfg and edit it to suit your
    needs.  Comments in it give some idea how.
run:
    wish sockptyr_gui.tcl
use:
    A list on the left of the GUI window will show connections.  Click
    on them to see details on the right side of the GUI window.  It will
    have buttons (depending on configuration and connection status) for
    doing things like starting up a terminal window connected to it.
alternate use:
    "sockptyr" includes a library of Tcl commands to perform its tasks
    including handling Unix domain sockets, pseudo-terminals, and
    (on Linux only) "inotify."  These can be used in your own programs
    if you choose.  See the document "sockptyr-tcl-api.txt" for usage.
license:
    Freely redistributable under Berkeley license
explanation of the name:
    Pronounced "sock-puh-teer".  Named in reference to its handling
    of sockets, pseudo-terminals (PTYs), and the word "puppeteer."
