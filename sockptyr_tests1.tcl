#!/usr/bin/tclsh
# sockptyr_tests1.tcl
# Copyright (C) 2019, Jeremy Dilatush.  All rights reserved.
#
# Some basic tests for the "C" part of "sockptyr".  These are not going
# to be full functional tests, but test some basics of its operation, meant for
# execution at build time.
#
# Run with the following command line:
#       tclsh sockptyr_tests1.tcl [-hang] $path_to_dyl $use_inotify
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
}
puts stderr "Done"

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
