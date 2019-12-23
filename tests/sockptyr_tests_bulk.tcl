#!/usr/bin/tclsh
# sockptyr_tests_bulk.tcl
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

# Test program for sockptyr.  In particular this tests the passage of
# data through connections.  It uses PTYs for connections but the results
# of the test will cover all connection types.
#
# Method of operation:
#       + Load sockptyr
#       + Create some number of pairs of PTYs
#       + Link the PTYs to each other
#       + Open the PTYs in Tcl
#       + Write/read data, checking it.
#
# Command line interface:
#   tclsh sockptyr_tests_bulk.tcl [-v] $pairs $max $downbias
# Example:
#   tclsh sockptyr_tests_bulk.tcl 5 1024 2
# Meaning:
#   "-v" increases output; may be repeated
#   Will open 2*$pairs PTYs
#   Will transfer up to $max bytes at a time.
#   $downbias reduces the typical size below $max.
# Runs until you stop it with control-C or the like.
#
# Actually has a second command line interface, on which it runs itself,
# which takes care of actually passing data between a pair of PTYs:
#   tclsh sockptyr_tests_bulk.tcl -d $verbose $max $downbias $wpty $rpty
#
# NOTE: When you control-C this it leaves the child processes running.
# That's not very nice but that's the way it turns out.  This is a test
# program, you should be prepared to deal with ugliness.

## ## special case: the "data handling" background process

if {[lindex $argv 0] eq "-d"} {
    # parameters
    lassign $argv _ verbose max downbias wpty rpty
    set max [expr {double($max)}]
    set downbias [expr {double($downbias)}]
    set bytes 0
    set next_status [expr {[clock seconds] + 1}]
    set status_interval 2

    set rfh [open $rpty r]
    set wfh [open $wpty w]
    fconfigure $rfh -buffering none -encoding binary -translation binary
    fconfigure $wfh -buffering none -encoding binary -translation binary

    while {1} {
        # Write some data.
        set r [expr {min(1, (rand() + 0.1) ** $downbias)}]
        set len [expr {1 + int(($max - 1) * $r)}]
        set wd ""
        while {[string length $wd] < $len} {
            append wd [format %c [expr {97+int(rand()*26)}]]
        }
        if {$verbose} {
            puts stderr "Writing $len bytes to $wpty"
        }
        puts -nonewline $wfh $wd

        # Read it back.
        if {$verbose} {
            puts stderr "Reading $len bytes from $rpty"
        }
        set rd [read $rfh $len]
        if {$rd ne $wd} {
            error "Data mismatch between write to $wpty, read from $rpty"
        }
        incr bytes $len

        # Occasional status updates
        if {[clock seconds] >= $next_status} {
            set next_status [expr {[clock seconds] + $status_interval}]
            set status_interval [expr {min(300, $status_interval * 2)}]
            set f {As of %s: %s -> %s passed %lld bytes (%.3e)}
            puts stderr [format $f \
                [clock format [clock seconds]] \
                $wpty $rpty $bytes $bytes]
        }
    }
}

## ## parameters
set verbose 0
while {[lindex $argv 0] eq "-v"} {
    set argv [lrange $argv 1 end]
    incr verbose
}

if {[llength $argv] != 3} {
    error "see comments at top of source code for usage help"
}
lassign $argv pairs max downbias

if {![string is integer -strict $pairs] || int($pairs) < 1} {
    error "\$pairs must be a positive integer"
}
set pairs [expr {int($pairs)}]
if {![string is double -strict $max] || !(double($max) >= 1)} {
    error "\$max must be a number at least 1"
}
set max [expr {double($max)}]
if {![string is double -strict $downbias] || !(double($downbias) >= 0)} {
    error "\$downbias must be a non-negative number"
}
set downbias [expr {double($downbias)}]

## ## load sockptyr's C code

foreach path {./sockptyr.so ./sockptyr.dylib ./sockptyr.dll} {
    if {![catch {load $path} err]} {
        break
    }
}
if {![llength [info commands sockptyr]]} {
    error "sockptyr library load failed"
}

## ## create the PTYs and link them and open them

# $npty - the number of PTYs; they'll be identified by numbers from 0
#         through $npty-1
# $ptyp($i) - pathname of PTY
# $ptyh($i) - handle of PTY
# $ptyl($i) - number of PTY it's linked to

set npty [expr {$pairs << 1}]
for {set i 0} {$i < $npty} {incr i} {
    lassign [sockptyr open_pty] ptyh($i) ptyp($i)
    set ptyl($i) ""
    puts stderr "Opened PTY: path $ptyp($i) handle $ptyh($i)"
}

set tolink $npty
set ptys_as_linked [list]
while {$tolink > 0} {
    # Pick two PTYs at random and if neither is already linked, link them.
    # This is an inefficient but simple way to do it, and ok for small
    # numbers of PTYs.
    set i [expr {int(rand()*$npty)}]
    set j [expr {int(rand()*$npty)}]
    if {$i != $j && $ptyl($i) eq "" && $ptyl($j) eq ""} {
        puts stderr "Linking PTYs: $ptyp($i) <==> $ptyp($j)"
        sockptyr link $ptyh($i) $ptyh($j)
        set ptyl($i) $j
        set ptyl($j) $i
        lappend ptys_as_linked $ptyp($i) $ptyp($j)
        incr tolink -2
    }
}

## ## now pass data

# child processes to read/write data
foreach {p1 p2} $ptys_as_linked {
    foreach {pw pr} [list $p1 $p2 $p2 $p1] {
        set cmd "[info nameofexecutable] [info script] -d $verbose"
        append cmd " $max $downbias $pw $pr &"
        puts stderr "Running: $cmd"
        exec sh -c $cmd >@stdout 2>@stderr
    }
}

# watch for errors & files being closed
proc spexc {i args} {
    global ptyp
    puts stderr "Something happened on ptyp($i): $args"
    exit 1
}
for {set i 0} {$i < $npty} {incr i} {
    sockptyr onclose $ptyh($i) [list spexc $i close]
    sockptyr onerror $ptyh($i) [list spexc $i error]
}

# and let sockptyr do its thing
vwait forever
