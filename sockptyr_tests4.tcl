#!/usr/bin/tclsh
# sockptyr_tests4.tcl
# Copyright (C) 2019, Jeremy Dilatush.  All rights reserved.
#
# Test program for sockptyr.  Not a full test by any means, and also not
# the automatable basic tests as in sockptyr_tests_auto.tcl.  What this one
# does is "churn" handles and other things within sockptyr, so you can
# look for leaks and the like.
#
# Takes directions on the command line:
#       keep # -- set number of "things" of each kind to keep
#       run # -- Perform churn (creation & removal of stuff) through the
#           specified number of cycles.
#       hd -- show handle debugging output
#       sleep # -- sleep for the specified number of seconds
# when it runs out of parameters it cleans up and exits.

set keep 0
set nctr 0
set octr 0
set sokpfx eraseme_tests4sok

# initialize
foreach path {./sockptyr.so ./sockptyr.dylib ./sockptyr.dll} {
    if {![catch {load $path} err]} {
        break
    }
}
if {![llength [info commands sockptyr]]} {
    puts stderr "sockptyr library load failed"
    exit 1
}

# find out if we have inotify
set USE_INOTIFY 0
foreach {n v} [sockptyr info] {
    if {$n eq "USE_INOTIFY"} {
        set USE_INOTIFY $v
    }
}

# clean up conflicting socket filenames
foreach s [glob -nocomplain -types s ${sokpfx}*] {
    catch {file delete $s}
}

# single "add" subcycle operation
proc add {cyc} {
    puts stderr "XXX add $cyc"
    # XXX
}

# single "del" subcycle operation
proc del {cyc} {
    puts stderr "XXX del $cyc"
    # XXX
}

# process directions from the command line
for {set i 0} {$i < [llength $argv]} {incr i} {
    set a [lindex $argv $i]
    if {$a eq "keep"} {
        incr i
        set keep [lindex $argv $i]
        if {![string is integer -strict $keep] || $keep < 0} {
            error "'keep $keep' not a nonnegative integer"
        }
        set keep [expr {int($keep)}]
    } elseif {$a eq "run"} {
        incr i
        set run [lindex $argv $i]
        if {![string is integer -strict $run] || $run < 0} {
            error "'run $run' not a nonnegative integer"
        }
        puts stderr "Running $run cycles now."
        for {set j 0} {$j < $run} {incr j} {
            if {$nctr <= $octr + $keep} {
                add $nctr
                incr nctr
            }
            if {$nctr > $octr + $keep} {
                del $octr
                incr octr
            }
        }
        puts stderr "Running $run cycles done."
    } elseif {$a eq "hd"} {
        array set dbg_handles [sockptyr dbg_handles]
        puts stderr "Handle debug:"
        foreach n [lsort [array names dbg_handles]] {
            puts stderr [format {    %20s: %s} $n $dbg_handles($n)]
        }
        if {[llength [array names dbg_handles]] < 1} {
            error "sockptyr dbg_handles gave us nothing"
        }
        if {[info exists dbg_handles(err)]} {
            error "sockptyr dbg_handles error: $dbg_handles(err)"
        }
        puts stderr "Handle debug done."
    } elseif {$a eq "sleep"} {
        incr i
        set sleep [lindex $argv $i]
        if {![string is double -strict $sleep] ||
            !($sleep >= 0 && $sleep < 86400.0)} {
            error "'sleep $sleep' is not a positive number less than 86400"
        }
        puts stderr "Sleeping $sleep seconds:"
        after [expr {int(ceil(double($sleep) * 1000))}]
        puts stderr "Sleep done."
    } else {
        error "Unknown direction '$a'"
    }
}

# final cleanup
puts stderr "Doing final cleanup cycles."
while {$octr < $nctr} {
    del $octr
    incr octr
}
exit 0

