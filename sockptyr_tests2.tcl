#!/usr/bin/tclsh
# sockptyr_tests2.tcl
# Copyright (C) 2019, Jeremy Dilatush.  All rights reserved.
#
# Test program for sockptyr.  Not a full test by any means, and also not
# the automatable basic tests as in sockptyr_tests1.tcl.  What this one
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
    global ptyh ptyp pty_ctr pty_sel0 pty_sel1

    set ch [read stdin 1]
    switch -- $ch {
        "+" {
            lassign [sockptyr open_pty] ptyh($pty_ctr) ptyp($pty_ctr)
            puts stderr "Opened PTY: $ptyp($pty_ctr)"
            incr pty_ctr
        }
        "." {
            sockptyr link $ptyh($pty_sel1) $ptyh($pty_sel2)
            puts stderr "Linked PTYs: $ptyp($pty_sel1) $pytp($pty_sel2)"
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
