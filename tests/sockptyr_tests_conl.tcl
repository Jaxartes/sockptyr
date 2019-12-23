#!/usr/bin/tclsh
# sockptyr_tests_conl.tcl
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
# does is test the basic operation of linked unix domain socket connections.
# Give it the pathname to the sockets on the command line.  It opens them
# and links them pairwise.

# And it can take some additional "commands" on stdin; all single character:
#       0-9 -- "select" one of the first 10 connections made
#       . -- join the last two connections selected
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
    global sokp
    puts stderr "$what on $sokp($which): $args"
}

set is [list]
foreach arg $argv {
    set sokp([llength $is]) $arg
    lappend is [llength $is]
}

foreach i $is {
    set sokh($i) [sockptyr connect $sokp($i)]
    sockptyr onclose $sokh($i) [list handle close $i]
    sockptyr onerror $sokh($i) [list handle error $i]
    puts stderr "Connected to socket: $sokp($i) (handle $sokh($i))"
}

foreach {i j} $is {
    if {$j eq ""} continue
    sockptyr link $sokh($i) $sokh($j)
    puts stderr "Linked sockets: $sokp($i) & $sokp($j)"
}
set sok_ctr 4
set sok_sel1 0
set sok_sel2 1

proc read_stdin {} {
    global sokh sokp sok_ctr sok_sel1 sok_sel2

    set ch [read stdin 1]
    switch -- $ch {
        "." {
            sockptyr link $sokh($sok_sel1) $sokh($sok_sel2)
            puts stderr "Linked sockets: $sokp($sok_sel1) $sokp($sok_sel2)"
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
                set sok_sel1 $sok_sel2
                set sok_sel2 $ch
            }
        }
    }
}

chan event stdin readable read_stdin

vwait forever
