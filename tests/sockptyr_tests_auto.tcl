#!/usr/bin/tclsh
# sockptyr_tests_auto.tcl
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

# Some basic tests for the "C" part of "sockptyr".  These are not going
# to be full functional tests, but test some basics of its operation, meant for
# execution at build time.
#
# Run with the following command line:
#       tclsh sockptyr_tests_auto.tcl [-hang] $path_to_dyl $use_inotify
# where
#       "-hang" if specified causes the script to wait 5 minutes before ending
#       $path_to_dyl is the path to the dynamic library file (called a .so
#           file on some operating systems) containing the code to test
#       $use_inotify is the value of USE_INOTIFY that code was compiled with

if {[lindex $argv 0] eq "-hang"} {
    set hang 1
    set argv [lrange $argv 1 end]
} else {
    set hang 0
}
lassign $argv path_to_dyl use_inotify
puts stderr "Running: [concat [list [info nameofexecutable] $argv0] $argv]"
puts stderr "path_to_dyl = $path_to_dyl"
puts stderr "use_inotify = $use_inotify"

puts stderr ""
puts stderr "Loading the C code to be tested..."
load $path_to_dyl sockptyr
puts stderr "Done"

puts stderr ""
puts stderr "Checking build information..."
array set sockptyr_info [sockptyr info]
foreach n [lsort [array names sockptyr_info]] {
    puts stderr [format {    sockptyr_info(%20s): %s} $n $sockptyr_info($n)]
}
if {$sockptyr_info(USE_INOTIFY) ne $use_inotify} {
    set g $sockptyr_info(USE_INOTIFY)
    set e $use_inotify
    error "USE_INOTIFY mismatch: compile time $g run time $e"
}

puts stderr ""
puts stderr "Opening ten PTYs..."
set pty_handles [list]
set pty_paths [list]
for {set i 0} {$i < 10} {incr i} {
    lassign [sockptyr open_pty] hdl path
    lappend pty_handles $hdl
    lappend pty_paths $path
    puts stderr "\tPTY $i/10: handle $hdl path $path"
    if {$i == 5} {
        sockptyr buffer_size 1024
    }
}
puts stderr "Done"

# "sockptyr connect" left out of this test because it's an annoying one,
# wanting a unix domain socket to connect to.

puts stderr ""
puts stderr "Linking some of them..."
set ijs [list]
lappend ijs 1 2 3 4 ; # will be changed by later links in the same list
for {set i 0} {$i < [llength $pty_handles] - 1} {incr i 3} {
    lappend ijs $i [expr {$i + 1}]
}
foreach {i j} $ijs {
    set h1 [lindex $pty_handles $i]
    set h2 [lindex $pty_handles $j]
    set p1 [lindex $pty_paths $i]
    set p2 [lindex $pty_paths $j]
    puts stderr "\t$p1 ($h1) to $p2 ($h2)"
    sockptyr link $h1 $h2
}
puts stderr "Done"

puts stderr ""
puts stderr "Setting onerror and onclose callbacks on some..."
proc my_generic_cb {args} {
    puts stderr "!!! [list my_generic_cb $args]"
}
sockptyr onclose [lindex $pty_handles 3] "my_generic_cb onclose 3"
sockptyr onclose [lindex $pty_handles 0] "my_generic_cb onclose 0"
sockptyr onerror [lindex $pty_handles 1] "my_generic_cb onerror 1"
sockptyr onclose [lindex $pty_handles 2] "my_generic_cb onclose 2"
sockptyr onclose [lindex $pty_handles 3]
puts stderr "Done"

puts stderr ""
puts stderr "Closing a handle (1st PTY -- [lindex $pty_handles 0])"
sockptyr close [lindex $pty_handles 0]
update
puts stderr "Done"

puts stderr ""
puts stderr "Connection ops on non-connection handle"
if {$use_inotify} {
    set nchdl [sockptyr inotify . IN_CREATE list]
} else {
    set nchdl [lindex $pty_handles 0]
}

foreach what {link onclose onerror} {
    foreach {opa oph opx} {1 Adding 1 0 Removing 0} {
        puts stderr "\t$oph $what on non-connection handle $nchdl"
        set cmd [list sockptyr]
        lappend cmd $what $nchdl
        if {$opa} {
            lappend cmd wxyz
        }
        puts stderr "\tCommand: $cmd"
        set rv [catch $cmd res]
        puts stderr "\tResult: $rv $res"
        if {(!!$rv) != $opx} {
            error "Unexpected result!"
        }
    }
}

puts stderr ""
puts stderr "Running handle debug..."
array set dbg_handles [sockptyr dbg_handles]
foreach n [lsort [array names dbg_handles]] {
    puts stderr [format {    %20s: %s} $n $dbg_handles($n)]
}
if {[llength [array names dbg_handles]] < 1} {
    error "sockptyr dbg_handles gave us nothing"
}
if {[info exists dbg_handles(err)]} {
    error "sockptyr dbg_handles error: $dbg_handles(err)"
}
puts stderr "Done"

if {$hang} {
    puts stderr ""
    puts stderr "Waiting 5 minutes on request (-hang)..."
    after 300000
    puts stderr "Done"
}

exit 0
