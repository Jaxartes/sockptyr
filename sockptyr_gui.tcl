#!wish
# sockptyr_gui.tcl
# Copyright (C) 2019, Jeremy Dilatush.  All rights reserved.
#
# GUI for sockptyr: A Tk application that monitors for connections you
# want to hook up to, and gives you buttons for, e.g. starting terminal
# windows hooked up to them.

# XXX work in progress

## ## ## Hard coded configuration

# Some of this information would ideally be moved to a configuration file,
# for easier editing.  But for now, just putting it in the Tcl script
# itself.

# $sockptyr_library_path: File pathname to load the sockptyr library
# (compiled from sockptyr_core.c).
set sockptyr_library_path ./sockptyr[info sharedlibextension]

# $config(...): Configuration of what we monitor and what we do with it.
# An array with various keys and values as follows:
#       Identify each connection with a label $label
#           which is also used in display etc
#           the label actually used depends on the connection source
#           for "listen": $label:$counter
#           for "connect": $label
#           for "directory": $label:[basename $filename]
#       set config($label:source) ...
#           specifies the connection source, one of the following lists
#           To listen for connections on a UNIX domain stream socket:
#               2 elements: listen $filename
#           To connect to a UNIX domain stream socket:
#               2 elements: connect $filename
#           To monitor a directory for UNIX domain stream sockets, and
#           connect to them:
#               3 elements: directory $dirname $interval
#               If "inotify" is available it uses that to monitor the
#               directory.  Otherwise it reads the directory every
#               $interval seconds.
#       set config($label:button:$text:icon) ...
#           Define something the user can do with any connection from
#           this source.  The value is the name of an image defined
#           within this program for use as a graphical button.  The $text
#           is a text string to go with it.
#       set config($label:button:$text:ptyrun) ...
#           When the button is activated, open a PTY and then execute
#           the specified program.  It's a shell command with limited
#           "%" substitution:
#               %% - "%"
#               %l - label
#               %p - PTY pathname
#       set config($label:button:$text:loopback) ...
#           When the button is activated, link the connection to itself
#           (loopback).

set config(LISTY:source) {listen ./sockptyr_test_env_l}
set config(LISTY:button:Terminal:icon) ico_term
set config(LISTY:button:Terminal:ptyrun) {xterm -fn 8x16 -geometry 80x24 -fg cyan -bg black -cr cyan -sb -T "%l" -n "%l" -e picocom %p}
set config(LISTY:button:Loopback:icon) ico_back
set config(LISTY:button:Loopback:loopback) 1
set config(CONN:source) {connect ./sockptyr_test_env_c}
set config(CONN:button:Terminal:icon) ico_term
set config(CONN:button:Terminal:ptyrun) {xterm -fn 8x16 -geometry 80x24 -fg cyan -bg black -cr cyan -sb -T "%l" -n "%l" -e picocom %p}
set config(CONN:button:Loopback:icon) ico_back
set config(CONN:button:Loopback:loopback) 1
set config(DIR:source) {directory ./sockptyr_test_env_d 20.0}
set config(DIR:button:Terminal:icon) ico_term
set config(DIR:button:Terminal:ptyrun) {xterm -fn 8x16 -geometry 80x24 -fg cyan -bg black -cr cyan -sb -T "%l" -n "%l" -e picocom %p}
set config(DIR:button:Loopback:icon) ico_back
set config(DIR:button:Loopback:loopback) 1

## ## ## GUI setup details, like where to find pictures

foreach {ilbl _ iset} {
    ico_term {a picture of a terminal or personal computer}
    {
        /usr/include/X11/bitmaps/terminal "xbitmaps package on Debian"
        /opt/local/include/X11/bitmaps/terminal "xbitmaps port in MacPorts"
    }
    ico_back {a picture of a bent-back arrow}
    {
        /usr/include/X11/bitmaps/FlipHoriz "x11-apps package on Debian"
        /opt/local/include/X11/bitmaps/FlipHoriz "xorg-apps package on Debian"
    }
} {
    foreach {ipath _} $iset {
        set notfound 1
        if {[file exists $ipath]} {
            if {[catch {image create bitmap $ilbl -file $ipath} err]} {
                puts stderr "Failed to load image $ipath: $err"
                continue
            }
            set notfound 0
            break
        }
    }
    if {$notfound} {
        puts stderr "No image found for '$ilbl'"
        # not a fatal error; but probably will turn out badly
    }
}

# lblfont - font for GUI labels
font create lblfont -family Times -size 18 -weight bold

# txtfont - font for general text
font create txtfont -family Times -size 12 -weight normal

# listwidth - list of scrolling connections list
set listwidth 192

# detwidth - list of detail display
set detwidth 384

# bgcolor - background color
# fgcolor - foreground color
set bgcolor lightgray
set fgcolor black

## ## ## GUI

wm iconname . "sockptyr"
wm title . "sockptyr"
wm resizable . 0 0

# window layout:
#       left side: scrolling list of connections
#       right side: info about selected connection; and some global options

frame .conns
canvas .conns.can -width $listwidth \
    -height 448 -yscrollcommand {.conns.sb set} \
    -scrollregion [list 0 0 $listwidth 0] -background $bgcolor
scrollbar .conns.sb -command {.conns.can yview}
pack .conns.can -side left
pack .conns.sb -side right -fill y
pack .conns -side left

frame .detail -width $detwidth
label .detail.l1 -text "sockptyr: details" -font lblfont -justify left
frame .detail.bbb
button .detail.bbb.x -text "Exit" -command {exit 0}
frame .detail.m
frame .detail.m.none
label .detail.m.none.l1 -text "No selection" -font lblfont -justify left \
    -wraplength $detwidth
label .detail.m.none.l2 -text "" -font txtfont -justify left \
    -wraplength $detwidth
label .detail.m.none.l3 -text "" -font txtfont -justify left \
    -wraplength $detwidth
frame .detail.m.conn

proc detail_select {which} {
    foreach which2 {none conn} {
        pack forget .detail.m.$which2
        if {$which eq $which2} {
            pack .detail.m.$which -fill both
        }
    }
}
detail_select none

pack propagate .detail 0
pack .detail.l1 -side top -fill x
pack .detail.bbb.x -side left
pack .detail.bbb -side bottom -fill x
pack .detail.m.none.l1 -side top -anchor w
pack .detail.m.none.l2 -side top -anchor w
pack .detail.m.none.l3 -side top -anchor w
pack .detail.m -fill both -expand 1
pack .detail -side right -fill both

proc badconfig {msg} {
    puts stderr "Bad hard coded configuration: $msg"
    .detail.m.none.l2 configure -text "Bad hard coded configuration"
    .detail.m.none.l3 configure -text $msg
    detail_select none
    vwait forever
}

## ## ## Load the sockptyr library

# The rationale for loading the library so late is that then you can see
# the GUI and the error message about loading the library, instead of
# having nothing come up.
update
if {[catch {load $sockptyr_library_path sockptyr} res]} {
    puts stderr "Failed to load sockptyr library from $sockptyr_library_path: $res"
    .detail.m.none.l2 configure -text "sockptyr library not loaded"
    detail_select none
    vwait forever
}

set sockptyr_info(USE_INOTIFY) 0 ; # will be overwritten from [sockptyr info]
array set sockptyr_info [sockptyr info]

## ## ## Connection handling

# About how connection entries in .conns.can are tracked:
#   $conn_hdls($label) maps the unique label string to a "sockptyr" handle
#       or "" if it's not ok
#   $conn_tags($label) maps the unique label string to a tag in .conns.can
#   $conn_line1($label) maps the unique label string to descriptive text
#   $conn_line2($label) maps the unique label string to descriptive text
#   $conn_link($label) identifies the connection it's linked to if any,
#                       by label
#   $conns lists the connections by unique label in order
# Some related tracking:
#   $listen_counter($label) is a counter to identify the connections
#       associated with label $label in $config(...).
#   $conn_tags() is a counter used for assigning $conn_tags(...) values.
#   $conn_sel is the selected connection's label

set conn_tags() 0

# conn_add: Called when there's a new connection to add to the list.
# Parameters:
#   $label -- source label from $config(...)
#   $ok -- boolean: is the connection ok (1) or did it fail somehow (0)
#   $source -- name of the connection source
#   $he -- if $ok is 0: $he is an error message
#          otherwise:   $he is a "sockptyr" connection handle
#   $qual -- if applicable, is a name or other qualifier that came up
#       when making the connection.  For instance, where $source = "directory"
#       and $ok = "1", $qual is the filename of the socket within the directory
proc conn_add {label ok source he qual} {
    puts stderr [list conn_add label $label ok $ok source $source he $he qual $qual]

    global conns conn_hdls conn_tags conn_desc conn_line1 conn_line2 conn_link
    global listwidth config fgcolor bgcolor

    # build a label for this connection
    switch -- $source {
        listen {
            global listen_counter
            if {![info exists listen_counter($label)]} {
                set listen_counter($label) 1
            }
            set conn [format {%s:%d} $label $listen_counter($label)]
            incr listen_counter($label)
        }
        connect {
            set conn $label
        }
        directory {
            set conn [format {%s:%s} $label $qual]
        }
        default {
            error "internal error: unknown source= $source"
        }
    }

    # make sure that label is text
    set conn2 ""
    for {set i 0} {$i < [string length $conn]} {incr i} {
        set ch [string index $conn $i]
        if {[string is graph -strict $ch] && $ch ne "\\"} {
            append conn2 $ch
        } else {
            append conn2 "?"
        }
    }
    set conn $conn2

    # make sure that label is unique (and nonempty)
    if {[info exists conn_tags($conn)] || $conn ne ""} {
        for {set i 0} {1} {incr i} {
            if {![info exists conn_tags($conn)]} {
                append $conn [format .%lld $i]
                break
            }
        }
    }

    # assign a tag for use in .conns.can
    incr conn_tags()
    set tag [format conn.%lld $conn_tags()]
    set conn_tags($conn) $tag

    # record details
    if {$ok} {
        set conn_hdls($conn) $he
    } else {
        set conn_hdls($conn) ""
    }
    set conn_link($conn) ""
    switch -- $source {
        listen {
            set conn_line1($conn) "Received socket connection"
            if {$ok} {
                set conn_line2($conn) \
                    "On: [lindex $config($label:source) 1]"
            } else {
                set conn_line2($conn) "Failed: $he"
            }
        }
        connect {
            set conn_line1($conn) "Socket connection"
            if {$ok} {
                set conn_line2($conn) \
                    "To: [lindex $config($label:source) 1]"
            } else {
                set conn_line2($conn) "Failed: $he"
            }
        }
        directory {
            set conn_line1($conn) "Socket connection (dir)"
            if {$ok} {
                set path [file join \
                    [lindex $config($label:source) 1] $qual]
                set conn_line2($conn) "To: $path"
            } else {
                set conn_line2($conn) "Failed: $he"
            }
        }
        default {
            error "internal error: unknown source= $source"
        }
    }

    # Create UI elements in .conns.can; positioned later.
    # tagging:
    #       $tag - all the stuff for this connection
    #       $tag.t - text label for the connection
    #       $tag.r - rectangule around the connection's stuff
    #       $tag.c - everything but $tag.r
    .conns.can create rectangle 0 0 0 0 \
        -fill $bgcolor -outline "" \
        -tags [list $tag $tag.r]
    .conns.can create text 0 0 \
        -font txtfont -fill $fgcolor -anchor nw \
        -text $conn -tags [list $tag $tag.t $tag.c]
    .conns.can bind $tag <Button-1> [list conn_sel $conn]

    # Record this connection's existence & put the connections in order.
    # This could obviously be done more efficiently but there are many
    # inefficiencies around that are about as bad.
    lappend conns $conn
    set conns [lsort $conns]

    # Reposition all the connection labels in .conns.can.
    set y 0
    foreach conn $conns {
        lassign [.conns.can bbox $conn_tags($conn).c] obx1 oby1 obx2 oby2
        .conns.can move $conn_tags($conn) 0 [expr {$y - $oby1}]
        lassign [.conns.can bbox $conn_tags($conn).c] nbx1 nby1 nbx2 nby2
        set y [expr {$y + $nby2 - $nby1}]
        .conns.can coords $conn_tags($conn).r 0 $nby1 $listwidth $nby2
    }
}

# conn_sel: Called to select a connection from the connection list.
# Parameters: unique connection label; or, empty string to deselect whatever's
# selected.
set conn_sel ""
proc conn_sel {conn} {
    puts stderr [list conn_sel $conn]

    global conn_sel bgcolor fgcolor conn_tags conn_line1 conn_line2

    if {$conn_sel ne ""} {
        # deselect the current one
        set tag $conn_tags($conn_sel)
        .conns.can itemconfigure $tag.r -fill $bgcolor
        .conns.can itemconfigure $tag.c -fill $fgcolor
    }

    if {$conn eq ""} {
        # selecting nothing
        .detail.m.none.l1 configure -text "No selection"
        .detail.m.none.l2 configure -text ""
        .detail.m.none.l3 configure -text ""
    } else {
        # selecting a particular connection
        set tag $conn_tags($conn)
        .detail.m.none.l1 configure -text $conn
        .detail.m.none.l2 configure -text $conn_line1($conn)
        .detail.m.none.l3 configure -text $conn_line2($conn)
        .conns.can itemconfigure $tag.r -fill $fgcolor
        .conns.can itemconfigure $tag.c -fill $bgcolor
    }

    set conn_sel $conn
}
conn_sel ""

# read_and_connect_dir: Read a directory and connect to any sockets in
# it that weren't seen in previous reads.
# Parameters:
#   $path -- pathname to the directory
#   $label -- source label from $config(...)
# Uses global $_racd_seen(...) to keep track of sockets it saw the last
# time through.  $_racd_seen($label) is a list, containing two entries
# for each socket seen last time on processing $label: the filename
# and... something else, doesn't matter.
proc read_and_connect_dir {path label} {
    global _racd_seen

    puts stderr [list read_and_connect_dir path $path label $label] ; # grot

    if {![info exists _racd_seen($label)]} {
        set _racd_seen($label) [list]
    }
    array set osockets $_racd_seen($label)

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
            if {[catch {sockptyr connect $fullpath} hdl]} {
                conn_add $label 0 directory $hdl $name
            } else {
                conn_add $label 1 directory $hdl $name
            }
        }
    }

    # and record what we saw, for comparison later
    set _racd_seen($label) [array get nsockets]
}

# read_and_connect_inotify: Run when "inotify" notifies us of a directory
# entry being added; see if it's a socket and if so connect to it.
# Parameters:
#   $path -- pathname to the directory
#   $label -- source label from $config(...)
#   $flags -- list of flags such as IN_CREATE
#   $cookie -- the API provides this to match related events together
#   $name -- name of file if any
proc read_and_connect_inotify {path label flags cookie name} {
    puts stderr [list read_and_connect_inotify path $path label $label flags $flags cookie $cookie name $name] ; # grot

    if {[lsearch -glob -nocase $flags *IGNORE] >= 0} {
        puts stderr "$path is gone and will no longer be monitored."
        # It's gone!  We won't get more events.  We could get rid of
        # this watch, but don't bother.
    }
    if {[lsearch -glob -nocase $flags *CREATE] >= 0} {
        set fullpath [file join $path $name]
        if {$name eq ""} {
            # huh?
            continue
        }
        if {[string match ".*" $name]} {
            # hidden file, skip
            continue
        }
        if {[catch {file type $fullpath} t] || $t ne "socket"} {
            # not a socket, skip
            continue
        }

        # here's a socket
        if {[catch {sockptyr connect $fullpath} hdl]} {
            conn_add $label 0 directory $hdl $name
        } else {
            conn_add $label 1 directory $hdl $name
        }
    }
}

# periodic: Execute $cmd every $ms milliseconds (or perhaps a bit longer).
proc periodic {ms cmd} {
    after $ms [list periodic $ms $cmd]
    uplevel "\#0" $cmd
}

## ## ## Now set things running

# Go through $config(...) to identify labels, and under each label, buttons.
# Ends up building:
#       $labels -- list of labels
#       $lbuttons($label) -- list of buttons per label
# and using arrays $_labels(...) and $_lbuttons(...) temporarily.
array unset _labels
array unset _lbuttons
array unset lbuttons
set labels [list]
foreach k [array names config] {
    lassign [split $k ":"] label lfield button bfield
    if {![info exists _labels($label)]} {
        lappend labels $label
        set _labels($label) 1
        set lbuttons($label) [list]
    }
    if {$lfield eq "button" && ![info exists _lbuttons($label:$button)]} {
        lappend lbuttons($label) $button
        set _lbuttons($label:$button) 1
    }
}

# Go through the configured labels and their buttons and set them up.
foreach label [lsort $labels] {
    if {![info exists config($label:source)]} {
        badconfig "label '$label' has no source"
        continue
    }
    set source [lindex $config($label:source) 0]
    switch -- $source {
        "listen" {
            lassign $config($label:source) source path
            if {[file exists $path] && [file type $path] eq "socket"} {
                catch {file delete -- $path}
            }
            sockptyr listen $path [list conn_add $label 1 listen]
        }
        "connect" {
            lassign $config($label:source) source path
            if {[catch {sockptyr connect $path} hdl]} {
                conn_add $label 0 connect $hdl ""
            } else {
                conn_add $label 1 connect $hdl ""
            }
        }
        "directory" {
            lassign $config($label:source) source path pollint

            # Monitor the directory to connect to its sockets.
            if {$sockptyr_info(USE_INOTIFY)} {
                # First find any sockets already in the directory.
                read_and_connect_dir $path $label

                # Use "inotify" to watch new ones.
                sockptyr inotify $path IN_CREATE \
                    [list read_and_connect_inotify $path $label]
            } else {
                # Schedule polling to happen, in which we read the directory
                # every so often to see if anything was added.
                periodic [expr {int(ceil($pollint * 1000.0))}] \
                    [list read_and_connect_dir $path $label]
            }
        }
        default {
            badconfig "label '$label' unrecognized source '$source'"
            continue
        }
    }
}

