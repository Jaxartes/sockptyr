#!/bin/sh
# sockptyr_d.tcl
# Copyright (c) 2020 Jeremy Dilatush
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

# the next line restarts using tclsh \
exec /usr/bin/tclsh "$0" ${1+"$@"}
# A command line / daemon for sockptyr: A Tcl program that monitors for
# connections you want to hook up to, allocates PTY devices for them,
# and maintains symbolic links for the PTY devices.
#
# This is not the main sockptyr program, for which see sockptyr_gui.tcl.
# This one is meant for when you don't have a GUI available.

# XXX work in progress: coded, only a little bit tested
# XXX high CPU utilization seen on linux sometimes
# XXX on macOS sometimes when I connect to the PTY it gets wedged

## ## ## Initialization

# figure out program name, for messages
set progname [file tail [info script]]
if {$progname eq ""} {
    set progname sockptyr_d.tcl
}

# usage: display a usage message and exit
proc usage {} {
    global progname

    puts stderr "USAGE: $progname \[options\] linksdir"
    puts stderr {
OPTIONS:
    -c path     Connect to socket at $path
    -l path     Listen for connections on socket at $path
    -d path     Monitor for sockets in directory $path
    -i sec      Interval for directory monitoring; only applicable with
                the -d option and then only on platforms lacking "inotify"
    -v          Increase the output detail
LINKSDIR:
    Directory in which symbolic links to the PTY corresponding to each
    connection will be maintained.  Must not contain anything other than
    this program's symbolic links -- which will be deleted upon start.
}
    exit 1
}

# load the sockptyr library, compiled from sockptyr.core.c
set sockptyr_library_path \
    [file join [file dirname [info script]] "sockptyr[info sharedlibextension]"]
load $sockptyr_library_path sockptyr
set sockptyr_info(USE_INOTIFY) 0
array set sockptyr_info [sockptyr info]

# parse the command line parameters
set cfg(srcchars) [list]; # -c/-l/-d: char "c", "l", "d" for each
set cfg(srcargs) [list] ; # -c/-l/-d: argument (path) for each
set cfg(monsec) 10.0    ; # -i option
set cfg(dir) ""         ; # linksdir
set cfg(v) 0            ; # verbose output
set cfg(retries) {200 300 500 1000 3000} ; # retry connection to new sockets

set opts [list]
for {set i 0} {$i < [llength $argv]} {incr i} {
    set a [lindex $argv $i]
    if {$a eq "--"} {
        # no more options
        incr i
        break
    }
    if {[string index $a 0] eq "-"} {
        # option characters
        for {set j 1} {$j < [string length $a]} {incr j} {
            set c [string index $a $j]
            switch -- $c {
                "c" - "l" - "d" - "i" {
                    # options which take parameters
                    if {$j < [string length $a] - 1} {
                        lappend opts $c [string range $a ${j}+1 end]
                        set a ""
                    } else {
                        incr i
                        lappend opts $c [lindex $argv $i]
                    }
                }
                "v" {
                    # options which don't take parameters
                    lappend opts $c ""
                }
                default {
                    # unrecognized options
                    puts stderr "$progname: Unrecognized option -$c"
                    usage
                }
            }
        }
    } else {
        # no more options
        break
    }
}

foreach {oc ov} $opts {
    switch -- $oc {
        "c" - "l" - "d" {
            lappend cfg(srcchars)   $oc
            lappend cfg(srcargs)    $ov
        }
        "i" {
            set cfg(monsec) $ov
            if {![string is double -strict $ov] || $ov < 0.1} {
                puts stderr "$progname: Out of range value with -i"
                usage
            }
        }
        "v" {
            incr cfg(v)
        }
        default {
            # shouldn't happen
            usage
        }
    }
}

if {$i < [llength $argv] - 1} {
    puts stderr "$progname: too many arguments"
    usage
}
if {$i >= [llength $argv]} {
    puts stderr "$progname: missing the linksdir argument"
    usage
}
set cfg(dir) [lindex $argv end]
if {![llength $cfg(srcchars)]} {
    puts stderr "$progname: need at least one -c, -l, or -d option"
    usage
}

# Find, check, and clean the linksdir
if {![file exists $cfg(dir)]} {
    puts stderr "$progname: $cfg(dir) doesn't exist"
    exit 1
}
if {![file isdirectory $cfg(dir)]} {
    puts stderr "$progname: $cfg(dir) is not a directory"
    exit 1
}
foreach sub [glob -directory $cfg(dir) -nocomplain *] {
    set ft [file type $sub]
    if {$ft eq "link"} {
        puts stderr "$progname: removing symbolic link $sub"
        file delete $sub
    } else {
        puts stderr "$progname: $sub is not a symbolic link (type is $ft)"
    }
}

## ## ## General utility functions

# stampy: display a message with a timestamp, depending on verbosity level
proc stampy {v msg} {
    global cfg

    if {$cfg(v) < $v} {
        # this message is not wanted
        return
    }

    set ms [clock milliseconds]
    set s [expr {entier($ms/1000)}]
    set ms [expr {$ms - $s * 1000}]
    puts stderr [format {%s.%03u - %s} \
        [clock format $s -format "%Y-%m-%d %H:%M:%S"] $ms $msg]
}

# bgerror: Report Tcl errors that occur in the background.
# This won't work well unless sockptyr_core.c was compiled with
# USE_TCL_BACKGROUNDEXCEPTION=1.
proc bgerror {msg} {
    global errorInfo cfg

    stampy 0 "BG error: $msg"
    foreach line [split $errorInfo "\n"] {
        if {$cfg(v) > 1} {
            puts stderr "ERROR INFO: $line"
        }
    }    
}

## ## ## Connection handling

# linkname: Build a link name out of a source identifier $si (counting
# from zero) and some other string.
proc linkname {si str} {
    global cfg

    if {[llength $cfg(srcchars)] > 1} {
        return [format %d_%s $si $str]
    } else {
        return $str
    }
}

# add_conn: Handle a new connection that's been made.  $hdl is the
# sockptyr handler for the new connection; allocate a PTY to go with it,
# hook them up, and make a symlink $linkname to it.  $desc is a descriptive
# string to use in messages.
proc add_conn {hdl linkname desc} {
    global cfg

    stampy 4 [list add_conn $hdl $linkname $desc]

    # Open a PTY.
    if {[catch {sockptyr open_pty} pty_hdl_path]} {
        stampy 0 "Unable to allocate pty for $desc: $pty_hdl_path"
        sockptyr close $hdl
        return
    }
    lassign $pty_hdl_path pty_hdl pty_path
    stampy 3 "Allocated pty $pty_path"
    stampy 4 "PTY handle $pty_hdl"

    # hook up the connection and the pty
    if {[catch {sockptyr link $hdl $pty_hdl} err]} {
        stampy 0 "Unable to connect $pty_hdl to $desc: $err"
        sockptyr close $hdl
        sockptyr close $pty_hdl
        return
    }
    stampy 3 "Connected $pty_path to new $desc"

    # make a symlink
    set linkpath [file join $cfg(dir) $linkname]
    if {[catch {file link -symbolic $linkpath $pty_path} err]} {
        stampy 0 "Unable to create symlink $linkname for $desc: $err"
        sockptyr close $hdl
        sockptyr close $pty_hdl
        return
    }

    stampy 1 "$linkname is link for new $desc"

    # Now the main activity, of transferring data over the connections,
    # is going to happen in sockptyr_core.c without this script's
    # involvement.  If something happens, a handler we register will
    # be called.  Now the time to register those handlers.
    sockptyr onclose $hdl \
        [list close_conn $linkname $pty_path $pty_hdl $hdl]
    sockptyr onerror $hdl \
        [list conn_error $linkname $linkname $pty_path $pty_hdl $hdl]
    sockptyr onerror $pty_hdl \
        [list conn_error $pty_path $linkname $pty_path $pty_hdl $hdl]
}

# add_conn_l: Wrapper for add_conn for use with "sockptyr listen"
# for the "-l" option.
# 
# Parameters:
#       si -- where the source appears in the list (0, 1, etc)
#       hdl -- new connection handle
#       empty -- empty string
proc add_conn_l {si hdl empty} {
    global l_counters
    set linkname [linkname $si $l_counters($si)]
    incr l_counters($si)
    add_conn $hdl $linkname "received connection"
}

# close_conn: Handle closure of a connection.  Callback for "sockptyr onclose".
#
# Parameters:
#       linkname -- filename of symbolic link
#       pty_path -- path of the PTY it's linked to
#       pty_hdl -- handle of the PTY
#       hdl -- handle of the connection
proc close_conn {linkname pty_path pty_hdl hdl} {
    global cfg

    stampy 1 "Connection ($linkname, $pty_path) closed."
    if {[catch {file delete [file join $cfg(dir) $linkname]} err]} {
        stampy 0 "Failed to delete $linkname: $err"
        # non fatal error, continue with cleanup
    }
    sockptyr onclose $pty_hdl
    sockptyr onclose $hdl
    sockptyr onerror $pty_hdl
    sockptyr onerror $hdl
    sockptyr close $pty_hdl
    sockptyr close $hdl
}

# conn_error: Handle error on a connection.  Callback for "sockptyr onerror".
#
# Parameters:
#   Supplied by the caller to "sockptyr onerror":
#       onwhat -- printable name of what it was on
#       linkname -- filename of symbolic link
#       pty_path -- path of the PTY it's linked to
#       pty_hdl -- handle of the PTY
#       hdl -- handle of the connection
#   Supplied by "sockptyr onerror" itself:
#       kws -- list of keywords like "bug", "io", "EPIPE"
#       msg -- printable message
proc conn_error {onwhat linkname pty_path pty_hdl hdl kws msg} {
    # report the error
    stampy 0 "Error on $onwhat: $msg"

    # see if it merits disconnecting
    set discon 0
    foreach kw $kws {
        switch -- $kw {
            "EIO" -
            "EPIPE" -
            "ECONNRESET" - 
            "ESHUTDOWN" {
                 set discon 1
            }
        }
    }

    if {$discon} {
        stampy 1 "Will close connection due to error"
        close_conn $linkname $pty_path $pty_hdl $hdl
    }
    # YYY consider adding logic to detect a fast spew of errors
}

# connect_with_retries:
# Try a few times to connect to a named socket $path.  When connection
# successful make it a link $linkname.  There will be one more connection
# attempts than entries in $retries; each entry in $retries is the
# number of milliseconds to wait between attempts
proc connect_with_retries {path linkname retries} {
    stampy 3 "Connecting to $path"
    if {![catch {sockptyr connect $path} hdl]} {
        # success
        add_conn $hdl $linkname "connection to $path"
    } elseif {[llength $retries]} {
        # try again
        stampy 3 "Will retry connection to $path"
        after [lindex $retries 0] \
            [list connect_with_retries $path $linkname [lrange $retries 1 end]]
    } else {
        # failure
        stampy 0 "Failed to connect to $path"
    }
}

# inotify_cb:
# Callback for "sockptyr inotify", will be run when a directory monitored
# with "-d" gets a new file.
#
# Parameters:
#   Parameters that were set up by the caller of "sockptyr inotify":
#       si -- source id number like 0, 1, etc
#       path -- directory path name being monitored
#   Parameters describing the particular inotify event received:
#       flags -- list of event flags like IN_ACCESS
#       cookie -- for associating related events
#       name -- name field if any, or empty string if not
proc inotify_cb {si path flags cookie name} {
    global cfg

    stampy 3 "Inotify event on $path: [list $flags $cookie $name]"
    if {[lsearch -glob -nocase $flags *IGNORE] >= 0} {
        stampy 0 "$path is gone and will no longer be monitored."
        # It's gone!  We won't get more events.  We could get rid of
        # this watch, but don't bother.
    }
    if {[lsearch -glob -nocase $flags *CREATE] < 0} {
        # not an interesting event
        return
    }
    
    set fullpath [file join $path $name]
    if {$name eq ""} {
        # huh?
        stampy 0 "inotify on $path gave us CREATE update w/o name"
        return
    }
    if {[string match ".*" $name]} {
        # hidden file, skip
        stampy 3 "ignoring new file $fullpath as it's hidden (a dotile)"
        return
    }
    if {[catch {file type $fullpath} t] || $t ne "socket"} {
        # not a socket, skip
        puts stderr "ignoring new file $fullpath as it's not a socket"
        return
    }

    # here's a socket
    connect_with_retries $fullpath [linkname $si $name] $cfg(retries)
}

# check_dir: Check a directory for new files for the "-d" option.
# After reading the directory contents and handling any new sockets,
# check_dir will either schedule itself to be run again or will enable
# monitoring with "inotify".
#
# Parameters:
#       si -- where the source appears in the list (0, 1, etc)
#       path -- path to the directory
proc check_dir {si path} {
    global sockptyr_info cfg _cd_seen

    stampy 2 "Reading directory $path to find sockets"

    # bookkeeping for record of what we've already seen
    if {![info exists _cd_seen($si)]} {
        set _cd_seen($si) [list]
    }
    array set osockets $_cd_seen($si)

    # read the directory
    foreach name [glob -directory $path -nocomplain -tails "*"] {
        set fullpath [file join $path $name]
        if {[string match ".*" $name]} {
            # skip hidden files
            continue
        }
        if {[file type $fullpath] ne "socket"} {
            # skip anything that's not a socket
            continue
        }
        set nsockets($name) 1
        if {![info exists osockets($name)]} {
            connect_with_retries \
                $fullpath [linkname $si $name] $cfg(retries)
        }
    }

    # bookkeeping for record of what we've already seen
    set _cd_seen($si) [array get nsockets]

    stampy 4 "osockets: [array names osockets]"
    stampy 4 "nsockets: [array names nsockets]"

    # start inotify, if possible; otherwise just schedule to re-scan the
    # directory a little later
    if {$sockptyr_info(USE_INOTIFY)} {
        set incmd [list inotify_cb $si $path]
        if {[catch {sockptyr inotify $path IN_CREATE $incmd} msg]} {
            stampy 0 "sockptyr inotify $path failed: $msg"
        } else {
            return
        }
    }

    set ms [expr {int($cfg(monsec) * 1000.0) + 1}]
    stampy 3 "Will read $path again in $ms milliseconds"
    after $ms [list check_dir $si $path]
}

for {set si 0} {$si < [llength $cfg(srcchars)]} {incr si} {
    set char [lindex $cfg(srcchars) $si]
    set arg  [lindex $cfg(srcargs) $si]
    switch -- $char {
        "c" {
            # -c $path -- connect to a socket given by path
            connect_with_retries \
                $arg [linkname $si [file tail $arg]] $cfg(retries)
        }
        "l" {
            # -l $path -- listen for connections on socket given by $path
            if {[file exists $arg] && [file type $arg] eq "socket"} {
                catch {file delete -- $arg}
            }
            set l_counters($si) 0
            sockptyr listen $arg [list add_conn_l $si]
        }
        "d" {
            # -d $path -- connect to sockets found in directory $path
            check_dir $si $arg
        }
    }
}

## ## ## Finally, wait for things to happen and handle them.

stampy 2 "Initialized, now waiting for things to happen"
vwait forever

