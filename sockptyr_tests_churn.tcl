#!/usr/bin/tclsh
# sockptyr_tests_churn.tcl
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
set sokpfx eraseme_churnsok

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

# database that keeps track of what we have open

# $db([list pty hdl $cyc]) - handle of PTY opened cycle $cyc
# $db([list pty path $cyc]) - name of PTY opened cycle $cyc
# $db([list lstn hdl $cyc]) - handle of listen socket opened cycle $cyc
# $db([list lstn path $cyc]) - path of listen socket opened cycle $cyc
# $db([list inot hdl $cyc]) - handle of inotify watch opened cycle $cyc
#                             (on this cycle's listen socket)
# $db([list conns hdl $cyc]) - handles of connections to & from cycle $cyc's
#                              listening socket
# $allconns - list of open connection handles
set allconns [list]

# acremove - remove a handle from $allconns if it's there, fail if not;
# this is inefficient but in a test program that's ok
proc acremove {hdl} {
    global allconns
    set allconns2 [list]
    set removed 0
    foreach hdl2 $allconns {
        if {$hdl eq $hdl2} {
            set removed 1
        } else {
            lappend allconns2 $hdl2
        }
    }
    if {!$removed} {
        error "$hdl not found in \$allconns"
    }
    set allconns $allconns2
}

# event callbacks
proc badcb {args} {
    # a callback to register when you expect it not to be called
    puts stderr "Bad callback: $args"
    exit 1
}

set accepted [list]
proc accept_proc {cyc hdl es} {
    # a callback to register for listening for connections
    # it'll append each connection's information to the global
    # $accepted in the form of two list entries:
    #       $cyc
    #       $hdl
    global accepted
    lappend accepted $cyc $hdl
    puts stderr "Accepted: $hdl (cyc=$cyc)"
}

# single "add" subcycle operation
proc add {cyc} {
    global db sokpfx allconns USE_INOTIFY accepted

    puts stderr "add($cyc)"

    # Open a PTY
    lassign [sockptyr open_pty] db([list pty hdl $cyc]) db([list pty path $cyc])
    lappend allconns $db([list pty hdl $cyc])
    sockptyr onclose $db([list pty hdl $cyc]) [list badcb pty $cyc i]
    update
    sockptyr onclose $db([list pty hdl $cyc])
    update
    sockptyr onclose $db([list pty hdl $cyc]) [list badcb pty $cyc ii]
    update
    sockptyr onclose $db([list pty hdl $cyc]) XXX
    update
    sockptyr onerror $db([list pty hdl $cyc]) [list badcb pty $cyc iii]
    update
    sockptyr onerror $db([list pty hdl $cyc])
    update
    sockptyr onerror $db([list pty hdl $cyc]) [list badcb pty $cyc iv]
    update
    sockptyr onerror $db([list pty hdl $cyc]) [list badcb pty $cyc v]
    update
    puts stderr "Opened PTY $db([list pty path $cyc])"
    puts stderr "Allocated handle is $db([list pty hdl $cyc])"

    # Open a listening socket
    set db([list lstn path $cyc]) $sokpfx$cyc
    set db([list lstn hdl $cyc]) \
        [sockptyr listen $db([list lstn path $cyc]) \
            [list accept_proc $cyc]]
    puts stderr "Opened listen socket $db([list lstn path $cyc])"

    # Connect (twice) to the listening socket
    set db([list conns hdl $cyc]) [list]
    for {set i 0} {$i < 2} {incr i} {
        set conn [sockptyr connect $db([list lstn path $cyc])]
        for {set j 0} {$j <2} {incr j} {
            puts stderr [list XXX i $i j $j conn $conn]
            lappend db([list conns hdl $cyc]) $conn
            lappend allconns $conn
            sockptyr onclose $conn [list badcb conn $cyc $i $j i]
            update
            sockptyr onclose $conn
            update
            sockptyr onclose $conn [list badcb conn $cyc $i $j ii]
            update
            sockptyr onclose $conn XXX
            update
            sockptyr onerror $conn [list badcb conn $cyc $i $j iii]
            update
            sockptyr onerror $conn
            update
            sockptyr onerror $conn [list badcb conn $cyc $i $j iv]
            update
            sockptyr onerror $conn [list badcb conn $cyc $i $j v]
            update
            if {$j} {
                break
            } else {
                # get the other end of the connection
                update
                while {![llength $accepted]} {
                    update
                }
                update
                foreach {acyc ahdl} $accepted {
                    if {$acyc != $cyc} {
                        error "Unexpectedly accepted connection on listen socket from cycle $acyc during cycle $cyc"
                    } else {
                        set conn $ahdl
                    }
                }
                if {[llength $accepted] > 2} {
                    error "More connections than expected!"
                }
            }
        }
    }
    update
    puts stderr "Connected to listen socket $db([list lstn path $cyc]) twice"

    # Link, or relink, or delink, some of our extant connections
    set c1 [lindex $allconns [expr {int(rand()*[llength $allconns])}]]
    set c2 [lindex $allconns [expr {int(rand()*[llength $allconns])}]]
    switch -- [expr {int(rand()*5)}] {
        0 {
            puts stderr "Unlinking connection"
            sockptyr link $c1
        }
        1 {
            puts stderr "Autolinking connection"
            sockptyr link $c1 $c1
        }
        default {
            puts stderr "Linking connections"
            sockptyr link $c1 $c2
        }
    }
    update
    puts stderr "(done)"

    if {$USE_INOTIFY} {
        # Add an inotify watch, on our listen socket
        set db([list inot hdl $cyc]) \
            [sockptyr inotify $db([list lstn path $cyc]) \
                IN_ATTRIB \
                XXX]
        update
        puts stderr "Added inotify watch on $db([list inot hdl $cyc])"
        
        # Make things happen to our inotify watch
        set t [file mtime $db([list lstn path $cyc])]
        incr t -3
        file mtime $db([list lstn path $cyc])
        update
        # XXX confirm it happened
        puts stderr "Triggered inotify watch"
    }
}

# single "del" subcycle operation
proc del {cyc} {
    global db allconns USE_INOTIFY

    puts stderr "del($cyc)"

    if {$USE_INOTIFY} {
        # Remove an inotify watch
        sockptyr close $db([list inot hdl $cyc])
        unset db([list inot hdl $cyc])
        update
        puts stderr "Inotify watch on $db([list lstn path $cyc]) removed"
    }

    # Close listening socket that was opened before; wait for the
    # connections to it to close
    set lpath $db([list lstn path $cyc])
    sockptyr close $db([list lstn hdl $cyc])
    unset db([list lstn path $cyc])
    unset db([list lstn hdl $cyc])
    while {[llength $db([list conns hdl $cyc])]} {
        # XXX
        update
        # XXX
    }
    unset db([list conns hdl $cyc])
    puts stderr "Listening socket $lpath and its connections closed."

    # Close the PTY that was opened before
    set ppath $db([list pty path $cyc])
    sockptyr close $db([list pty hdl $cyc])
    acremove $db([list pty hdl $cyc])
    update
    # XXX see that the close handler is called
    unset db([list pty path $cyc])
    unset db([list pty hdl $cyc])
    puts stderr "Closed pty $ppath"
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

