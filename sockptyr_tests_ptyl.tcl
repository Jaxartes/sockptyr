#!/usr/bin/tclsh
# sockptyr_tests_ptyl.tcl
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

# Test program for sockptyr.  Not a full test by any means, and also not
# the automatable basic tests as in sockptyr_tests_auto.tcl.  What this one
# does is test the basic operation of linked "connections".  It opens
# four PTYs and links them together.

# And it can take some additional "commands" on stdin; all single character:
#       + -- allocate a new pty
#       0-9 -- "select" one of the first ptys allocated
#       . -- join the last two ptys selected
#       ? -- query connection state for debug, with "sockptyr dbg_handles"

foreach path {./sockptyr.so ./sockptyr.dylib ./sockptyr.dll} {
    if {![catch {load $path} err]} {
        break
    }
}
if {![llength [info commands sockptyr]]} {
    puts stderr "sockptyr library load failed"
    exit 1
}

proc handle {what which args} {
    global ptyp
    puts stderr "$what on $ptyp($which): $args"
}

foreach i {0 1 2 3} {
    lassign [sockptyr open_pty] ptyh($i) ptyp($i)
    sockptyr onclose $ptyh($i) [list handle close $i]
    sockptyr onerror $ptyh($i) [list handle error $i]
    puts stderr "Opened PTY: $ptyp($i)"
}

foreach {i j} {0 1 2 3} {
    sockptyr link $ptyh($i) $ptyh($j)
    puts stderr "Linked PTYs: $ptyp($i) & $ptyp($j)"
}
set pty_ctr 4
set pty_sel1 0
set pty_sel2 1

proc read_stdin {} {
    global ptyh ptyp pty_ctr pty_sel1 pty_sel2

    set ch [read stdin 1]
    switch -- $ch {
        "+" {
            lassign [sockptyr open_pty] ptyh($pty_ctr) ptyp($pty_ctr)
            puts stderr "Opened PTY: $ptyp($pty_ctr)"
            incr pty_ctr
        }
        "." {
            sockptyr link $ptyh($pty_sel1) $ptyh($pty_sel2)
            puts stderr "Linked PTYs: $ptyp($pty_sel1) $ptyp($pty_sel2)"
        }
        "?" {
            array set data [sockptyr dbg_handles]
            puts stderr "sockptyr dbg_handles gives:"
            foreach n [lsort [array names data]] {
                puts stderr [format "    %20s %s" $n $data($n)]
            }
        }
        default {
            if {[string is digit -strict $ch]} {
                set pty_sel1 $pty_sel2
                set pty_sel2 $ch
            }
        }
    }
}

chan event stdin readable read_stdin

vwait forever
