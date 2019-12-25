#!/usr/bin/tclsh
# sockptyr_tests_cbulk2.tcl
# Copyright (c) 2019 Jeremy Dilatush
# All rights reserved.
# 
# Redistribution and use in source and binary forms, with or without
# modification, are permitted provided that the following conditions
# are met:
# 1. Redistributions of source code must retain the above copyright
#    notice, this list of conditions and the following disclaimer.
# 2. Redistributions in binary form must reproduce the above copyright
#    notice, this list of conditions and the following disclaimer in the
#    documentation and/or other materials provided with the distribution.
# 
# THIS SOFTWARE IS PROVIDED BY JEREMY DILATUSH AND CONTRIBUTORS
# ``AS IS'' AND ANY EXPRESS OR IMPLIED WARRANTIES, INCLUDING, BUT NOT LIMITED
# TO, THE IMPLIED WARRANTIES OF MERCHANTABILITY AND FITNESS FOR A PARTICULAR
# PURPOSE ARE DISCLAIMED.  IN NO EVENT SHALL JEREMY DILATUSH OR CONTRIBUTORS
# BE LIABLE FOR ANY DIRECT, INDIRECT, INCIDENTAL, SPECIAL, EXEMPLARY, OR
# CONSEQUENTIAL DAMAGES (INCLUDING, BUT NOT LIMITED TO, PROCUREMENT OF
# SUBSTITUTE GOODS OR SERVICES; LOSS OF USE, DATA, OR PROFITS; OR BUSINESS
# INTERRUPTION) HOWEVER CAUSED AND ON ANY THEORY OF LIABILITY, WHETHER IN
# CONTRACT, STRICT LIABILITY, OR TORT (INCLUDING NEGLIGENCE OR OTHERWISE)
# ARISING IN ANY WAY OUT OF THE USE OF THIS SOFTWARE, EVEN IF ADVISED OF THE
# POSSIBILITY OF SUCH DAMAGE.

# Test program for sockptyr.  Acts as a counterpart to sockptyr_tests_bulk2.c
# for tests that don't involve the GUI.  Requires "inotify".

set cfg(connect_dly_ms) 2000 ; # typical delay before connecting, in ms

# keeping track of connections known:
#       $chdl($path) handle for connection
#       $clnk($path) path of connection it's linked to if any, "" otherwise
#       $conns list of connections, may have some extras that have been
#           closed but not yet cleaned up
set conns [list]

proc dmsg {msg} {
    set us [clock microseconds]
    set s [expr {entier($us / 1000000)}]
    set us [expr {$us % 1000000}]
    set t [clock format $s -format %H:%M:%S]
    puts stderr [format "%s.%06u: %s" $t $us $msg]
}

if {[llength $argv] < 2} {
    puts stderr "SYNTAX: tclsh sockptyr_tests_cbulk2.tcl path-to-library directories-to-monitor..."
    exit 1
}

load [lindex $argv 0]

foreach mondir [lrange $argv 1 end] {
    sockptyr inotify $mondir IN_CREATE [list hdl_inotify $mondir]
}

proc hdl_inotify {mondir flags cookie name} {
    # file appeared; see if we can use it

    global cfg

    if {[lsearch -glob -nocase $flags *CREATE] < 0} {
        dmsg "uninteresting event ($flags) on $mondir"
        return
    }
    if {$name eq ""} {
        dmsg "creation of empty-named file?! on $mondir"
        return
    }
    set path [file join $mondir $name]
    if {[catch {file type $path} t] || $t ne "socket"} {
        dmsg "$path not a socket, ignoring"
        return
    }

    # schedule connecting to it
    set dly 0
    while {1} {
        set dly [expr {$dly + int($cfg(connect_dly_ms)*rand()) + 1}]
        if {rand() < 0.5} {
            break
        }
    }
    dmsg "see new socket $path, will connect in about $dly ms"
    after $dly [list hdl_connect $path]
}

proc hdl_connect {path} {
    # connect to file, then link the connection to another (or itself)

    global cfg chdl clnk conns

    # redundancy check
    if {[info exists chdl($path)]} {
        dmsg "Already connected to $path, not doing again"
        return
    }

    # connect
    if {[catch {sockptyr connect $path} hdl]} {
        dmsg "Failed to connect to $path: $hdl"
        return
    } else {
        dmsg "Connected to $path (handle= $hdl)"
    }

    # record the connection
    lappend conns $path
    set chdl($path) $hdl
    set clnk($path) ""

    # pick another connection to link it to
    while {1} {
        # pick a pseudorandom one
        set link [lindex $conns [expr {int(rand()*[llength $conns])}]]

        if {[info exists chdl($link)]} {
            # and it really exists
            break
        }

        # it must have been deleted; trim the list $conns
        set conns2 [list]
        foreach link $conns {
            if {[info exists chdl($link)]} {
                lappend conns2 $link
            }
        }
        set conn $conns2
    }

    if {$clnk($link) ne ""} {
        dmsg "Unlinking $link from $clnk($link)"
    }
    dmsg "Linking $path to $link"
    if {[catch {sockptyr link $chdl($path) $chdl($link)} err]} {
        dmsg "sockptyr link error: $err"
    } else {
        set clnk($path) $link
        set clnk($link) $path
    }

    sockptyr onclose $chdl($path) [list hdl_onclose $path]
    sockptyr onerror $chdl($path) [list hdl_onerror $path]
}

proc hdl_onclose {path} {

    global cfg chdl clnk conns

    dmsg "$path: closing"
    if {$clnk($path) ne ""} {
        dmsg "$clnk($path): no longer linked due to closure"
        set clnk($clnk($path)) ""
    }
    set hdl $chdl($path)
    unset clnk($path)
    unset chdl($path)
    sockptyr onclose $hdl
    sockptyr onerror $hdl
    sockptyr close $hdl
}

proc hdl_onerror {path errinfo errmsg} {
    dmsg "$path: $errmsg"

    foreach ei $errinfo {
        switch $ei {
            "EIO" -
            "EPIPE" -
            "ECONNRESET" -
            "ESHUTDOWN" {
                # looks like connection was closed
                hdl_onclose $path
                return
            }
        }
    }
}

vwait forever

