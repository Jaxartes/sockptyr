#!/usr/bin/tclsh
# sockptyr_tests_churn.tcl
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
# does is "churn" handles and other things within sockptyr, so you can
# look for leaks and the like.
#
# Takes directions on the command line:
#       keep # # -- set number of "things" of each kind to keep; is a range
#           so there can be some pseudorandom variation
#       run # -- Perform churn (creation & removal of stuff) through the
#           specified number of halfcycles.
#       hd -- show handle debugging output
#       sleep # -- sleep for the specified number of seconds
#       hdalways -- run handle debugging output frequently
#           but only check for errors
#       cleanup -- clean up, as is done at the end of the run
# when it runs out of parameters it cleans up and exits.

set keep_min 0
set keep_max 0
set nctr 0
set octr 0
set sokpfx eraseme_churnsok
set hdalways 0

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
# $db([list conns hdl $cyc]) - Two connection handles for each connection
#                              we make to $cyc's listen socket. In each
#                              pair the first is the "client" and the second
#                              is the "server".
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

proc hderrorcheck {} {
    # hderrorcheck: run "sockptyr dbg_handles" and ignore the result
    # except for error; throw any error as an exception
    array set dbg_handles [sockptyr dbg_handles]
    if {[info exists dbg_handles(err)]} {
        error "sockptyr dbg_handles error: $dbg_handles(err)"
    }
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

set expected_closes_cnt 0
proc expected_closes_proc {hdl} {
    # A callback to register for onclose that removes entries from
    # the expected_closes array when it's called
    global expected_closes expected_closes_cnt
    puts stderr [list EC [array get expected_closes]]
    if {![info exists expected_closes($hdl)] ||
        $expected_closes($hdl) < 1} {
        puts stderr "expected_closes_proc: Unexpected ($hdl)"
        exit 1
    }
    unset expected_closes($hdl)
    incr expected_closes_cnt
    sockptyr close $hdl
    acremove $hdl
}

set inotify_events [list]
proc inotify_proc {tag mask cookie name} {
    # Callback for inotify.  Records its parameters in inotify_events.
    global inotify_events
    puts stderr [list INOT $tag $mask $cookie $name]
    lappend inotify_events $tag $mask $cookie $name
}

# single "add" subcycle operation
proc add {cyc} {
    global db sokpfx allconns USE_INOTIFY accepted hdalways inotify_events

    puts stderr "add($cyc)"

    # Open a PTY
    lassign [sockptyr open_pty] db([list pty hdl $cyc]) db([list pty path $cyc])
    set hdl $db([list pty hdl $cyc])
    lappend allconns $db([list pty hdl $cyc])
    sockptyr onclose $db([list pty hdl $cyc]) [list badcb pty $cyc i $hdl]
    update
    sockptyr onclose $db([list pty hdl $cyc])
    update
    sockptyr onclose $db([list pty hdl $cyc]) [list badcb pty $cyc ii $hdl]
    update
    sockptyr onerror $db([list pty hdl $cyc]) [list badcb pty $cyc iii $hdl]
    update
    sockptyr onerror $db([list pty hdl $cyc])
    update
    sockptyr onerror $db([list pty hdl $cyc]) [list badcb pty $cyc iv $hdl]
    update
    sockptyr onerror $db([list pty hdl $cyc]) [list badcb pty $cyc v $hdl]
    update
    puts stderr "Opened PTY $db([list pty path $cyc])"
    puts stderr "Allocated handle is $db([list pty hdl $cyc])"
    if {$hdalways} { hderrorcheck }

    # Open a listening socket
    set db([list lstn path $cyc]) $sokpfx$cyc
    set db([list lstn hdl $cyc]) \
        [sockptyr listen $db([list lstn path $cyc]) \
            [list accept_proc $cyc]]
    puts stderr "Opened listen socket $db([list lstn path $cyc])"
    if {$hdalways} { hderrorcheck }

    # Connect (twice) to the listening socket
    set db([list conns hdl $cyc]) [list]
    for {set i 0} {$i < 2} {incr i} {
        set conn [sockptyr connect $db([list lstn path $cyc])]
        for {set j 0} {$j <2} {incr j} {
            lappend db([list conns hdl $cyc]) $conn
            lappend allconns $conn
            sockptyr onclose $conn [list badcb conn $cyc $i $j i $conn]
            update
            sockptyr onclose $conn
            update
            sockptyr onclose $conn [list badcb conn $cyc $i $j ii $conn]
            update
            sockptyr onerror $conn [list badcb conn $cyc $i $j iii $conn]
            update
            sockptyr onerror $conn
            update
            sockptyr onerror $conn [list badcb conn $cyc $i $j iv $conn]
            update
            sockptyr onerror $conn [list badcb conn $cyc $i $j v $conn]
            update
            if {$j} {
                break
            } else {
                # get the other end of the connection
                update
                while {![llength $accepted]} {
                    vwait $accepted
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
                set accepted [list]
            }
        }
    }
    update
    puts stderr "Connected to listen socket $db([list lstn path $cyc]) twice"
    if {$hdalways} { hderrorcheck }

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
    if {$hdalways} { hderrorcheck }

    if {$USE_INOTIFY} {
        # Add an inotify watch, on our listen socket
        set db([list inot hdl $cyc]) \
            [sockptyr inotify $db([list lstn path $cyc]) \
                IN_ATTRIB \
                [list inotify_proc $cyc]]
        update
        puts stderr "Added inotify watch $db([list inot hdl $cyc]) on $db([list lstn path $cyc])"
        if {$hdalways} { hderrorcheck }
        
        # Make things happen to our inotify watch
        set t [file mtime $db([list lstn path $cyc])]
        incr t -3
        file mtime $db([list lstn path $cyc]) $t
        while {![llength $inotify_events]} {
            vwait inotify_events
        }
        if {[llength $inotify_events] > 4} {
            error "Too many inotify events: $inotify_events"
        }
        lassign $inotify_events evtag evmask evcookie evname
        if {$evtag ne $cyc} {
            error "Wrong inotify event: tag $evtag exp $cyc, in $inotify_events"
        }
        if {[lsearch $evmask IN_ATTRIB] < 0} {
            error "Wrong inotify event: IN_ATTRIB not in $inotify_events"
        }
        set inotify_events [list]
        
        puts stderr "Triggered and checked inotify watch"
        if {$hdalways} { hderrorcheck }
    }

    # run a command in a shell
    switch -- [expr {int(rand()*8)}] {
        0 -
        1 -
        2 {
            set cmd "exit 0"
            set exp "exit 0"
        }
        3 -
        4 {
            set cmd "exit 1"
            set exp "exit 1"
        }
        5 -
        6 {
            set sec [expr {(rand() < 0.01) ? 300 : 3}]
            set cmd "sleep $sec &"
            set exp "exit 0"
        }
        7 {
            set cmd "kill -9 $$"
            set exp "signal Killed"
        }
    }
    puts stderr "Running shell command: $cmd"
    set got [sockptyr exec $cmd]
    puts stderr "Result: $got"
    if {$got eq $exp} {
        # ok
    } elseif {$got eq "signal {Killed: 9}" && $exp eq "signal Killed"} {
        # also ok
    } else {
        error "Result not what was expected"
    }
    update
}

# single "del" subcycle operation
proc del {cyc} {
    global db allconns USE_INOTIFY
    global expected_closes expected_closes_cnt hdalways

    puts stderr "del($cyc)"

    if {$USE_INOTIFY} {
        # Remove an inotify watch
        sockptyr close $db([list inot hdl $cyc])
        unset db([list inot hdl $cyc])
        update
        puts stderr "Inotify watch on $db([list lstn path $cyc]) removed"
        if {$hdalways} { hderrorcheck }
    }

    # Close listening socket that was opened before.
    set lpath $db([list lstn path $cyc])
    sockptyr close $db([list lstn hdl $cyc])
    file delete $lpath
    unset db([list lstn path $cyc])
    unset db([list lstn hdl $cyc])
    puts stderr "Listening socket $lpath removed"
    if {$hdalways} { hderrorcheck }

    # Close connections made through that listening socket.  Close one
    # end of each, chosen pseudorandomly, and wait for the other to
    # be closed too.

    foreach {conn1 conn2} $db([list conns hdl $cyc]) {
        if {rand() < 0.5} {
            lassign [list $conn2 $conn1] conn1 conn2
        }
        set expected_closes($conn2) 1
        sockptyr onclose $conn1 [list expected_closes_proc $conn1] ; #not called
        sockptyr onclose $conn2 [list expected_closes_proc $conn2]
        sockptyr close $conn1
        acremove $conn1
    }
    while {[array size expected_closes]} {
        vwait expected_closes_cnt
    }
    unset db([list conns hdl $cyc])
    puts stderr "Listening socket $lpath's connections closed."
    if {$hdalways} { hderrorcheck }

    # Close the PTY that was opened before
    set ptyh $db([list pty hdl $cyc])
    sockptyr onclose $ptyh) [list expected_closes_proc $ptyh] ; # not called
    set ppath $db([list pty path $cyc])
    sockptyr close $ptyh
    acremove $ptyh
    unset db([list pty path $cyc])
    unset db([list pty hdl $cyc])
    puts stderr "Closed pty $ppath"
    if {$hdalways} { hderrorcheck }
}

# process directions from the command line
for {set i 0} {$i < [llength $argv]} {incr i} {
    set a [lindex $argv $i]
    if {$a eq "keep"} {
        incr i
        set keep_min [lindex $argv $i]
        incr i
        set keep_max [lindex $argv $i]
        if {![string is integer -strict $keep_min] || int($keep_min) < 0 ||
            ![string is integer -strict $keep_max] ||
            int($keep_min) < 0 || int($keep_max) < int($keep_min)} {
            error "'keep $keep_min $keep_max' not an ordered nonnegative integer pair"
        }
        set keep_min [expr {int($keep_min)}]
        set keep_max [expr {int($keep_max)}]
    } elseif {$a eq "run"} {
        incr i
        set run [lindex $argv $i]
        if {![string is integer -strict $run] || $run < 0} {
            error "'run $run' not a nonnegative integer"
        }
        set runsave $run
        puts stderr "Running $runsave halfcycles now."
        while {$run > 0} {
            if {$nctr <= $octr + $keep_max && rand() < 0.5} {
                add $nctr
                incr nctr
                incr run -1
            } elseif {$nctr > $octr + $keep_min && rand() < 0.5} {
                del $octr
                incr octr
                incr run -1
            }
        }
        puts stderr "Running $runsave cycles done."
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
        array unset usages_cnt
        array unset usages_max
        foreach n [array names dbg_handles] {
            if {[llength $n] == 2 && [lindex $n 1] eq "usage"} {
                set hdl [lindex $n 0]
                set usage $dbg_handles($n)
                if {![info exists usages_cnt($usage)]} {
                    set usages_cnt($usage) 0
                    set usages_max($usage) 0
                }
                incr usages_cnt($usage)
                set usages_max($usage) [expr {max($usages_max($usage), $hdl)}]
            }
        }
        foreach usage [lsort [array names usages_cnt]] {
            puts stderr "handles with usage $usage: count $usages_cnt($usage) max $usages_max($usage)"
        }
        puts stderr "Handle debug done."
    } elseif {$a eq "hdalways"} {
        set hdalways 1
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
    } elseif {$a eq "cleanup"} {
        puts stderr "Doing commanded cleanup cycle if any applicable."
        while {$octr < $nctr} {
            del $octr
            incr octr
        }
    } else {
        error "Unknown direction '$a'"
    }
}

# final cleanup
puts stderr "Doing final cleanup cycles if any."
while {$octr < $nctr} {
    del $octr
    incr octr
}
puts stderr "Exiting."
exit 0

