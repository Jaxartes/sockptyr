#!/usr/bin/tclsh
# sockptyr_tests2.tcl
# Copyright (C) 2019, Jeremy Dilatush.  All rights reserved.
#
# Test program for sockptyr.  Not a full test by any means, and also not
# the automatable basic tests as in sockptyr_tests1.tcl.  What this one
# does is test the basic operation of linked "connections".  It opens
# four PTYs and links them together.

# XXX work in progress
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
    lassign [sockptyr link $ptyh($i) $ptyh($j)]
    puts stderr "Linked PTYs: $ptyp($i) & $ptyp($j)"
}

vwait forever
