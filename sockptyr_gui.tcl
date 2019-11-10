#!/bin/sh
# sockptyr_gui.tcl
# Copyright (C) 2019, Jeremy Dilatush.  All rights reserved.
#
# the next line restarts using wish \
exec /usr/bin/wish "$0" ${1+"$@"}
# GUI for sockptyr: A Tk application that monitors for connections you
# want to hook up to, and gives you buttons for, e.g. starting terminal
# windows hooked up to them.

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
#       set config($label:button:$num:...)
#           Configuration for buttons on the connection from this source.
#           The buttons are numbered 0, 1, etc.  See below for details
#           to be included.
#
#           There should be at least two buttons, one to use the connection
#           somehow and one to close it.  Perhaps more.
#       set config($label:button:$num:text) ...
#           Text to show on the button
#       set config($label:button:$num:always) ...
#           Flag indicating this button is always applicable even when the
#           connection has been disconnected.  1 is true, 0 or absence is
#           false.
#       set config($label:button:$num:action) ...
#           Tcl list defining action to perform for this button.
#           It's a partial Tcl command to which the following will be
#           appended:
#               config label
#               full label
#           Pre-coded commands:
#               conn_action_ptyrun $cmd $statlong $statshort $cfglbl $fulllbl
#                   Open a PTY and execute the specified program $cmd,
#                   a shell command with limited "%" substitution:
#                       %% - "%"
#                       %l - full label
#                       %p - PTY pathname
#                   Usually the command should end with "&".
#                   $statlong & $statshort are long & short status strings
#                   to show for the connection once this is done.
#               conn_action_loopback $cfglbl $fulllbl
#                   Hook the connection up to itself (loopback).
#               conn_action_close $cfglbl $fulllbl
#                   Close the connection and get rid of it.

set config(LISTY:source) {listen ./sockptyr_test_env_l}
set config(LISTY:button:0:text) Terminal
set config(LISTY:button:0:action) {conn_action_ptyrun {xterm -fn 8x16 -geometry 80x24 -fg cyan -bg black -cr cyan -sb -T "%l" -n "%l" -e picocom %p &} Terminal T}
set config(LISTY:button:1:text) Loopback
set config(LISTY:button:1:action) conn_action_loopback
set config(LISTY:button:2:text) Close
set config(LISTY:button:2:action) conn_action_close
set config(LISTY:button:2:always) 1
set config(CONN:source) {connect ./sockptyr_test_env_c}
set config(CONN:button:0:text) Terminal
set config(CONN:button:0:action) {conn_action_ptyrun {xterm -fn 8x16 -geometry 80x24 -fg cyan -bg black -cr cyan -sb -T "%l" -n "%l" -e picocom %p &} Terminal T}
set config(CONN:button:1:text) Loopback
set config(CONN:button:1:action) conn_action_loopback
set config(CONN:button:2:text) Close
set config(CONN:button:2:action) conn_action_close
set config(CONN:button:2:always) 1

## ## ## GUI setup details, like where to find pictures

rename send {}

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

# winheight - height of window
set winheight 448

# bgcolor - background color
# fgcolor - foreground color
# bgcolor2 - slightly highlighted background color
set bgcolor     "#d9d9d9"
set bgcolor2    "#bababa"
set fgcolor     "#000000"

set aqua_fake_buttons 1

## ## ## GUI

# Hack to deal with bug in macOS native interface "aque" in which the buttons
# show up blank.  This just makes a fake "button" implementation out of a label.
if {$aqua_fake_buttons && [tk windowingsystem] eq "aqua"} {
    puts stderr "macOS aqua hack running"

    set fake_btn_cfg(nfg) black     ; # normal foreground color
    set fake_btn_cfg(nbg) white     ; # normal background color
    set fake_btn_cfg(nre) raised    ; # normal relief
    set fake_btn_cfg(afg) black     ; # actuated foreground color
    set fake_btn_cfg(abg) white     ; # actuated background color
    set fake_btn_cfg(are) sunken    ; # actuated relief
    set fake_btn_cfg(bwd) 5         ; # border width
    set fake_btn_cfg(fnt) lblfont   ; # font

    proc fake_btn {bname args} {
        global fake_btn_state fake_btn_cfg

        set btext "?"
        set bcommand [list puts stderr "Unhandled button press $bname"]
        foreach {o v} $args {
            switch -- $o {
                "-text" {
                    set btext $v
                }
                "-command" {
                    set bcommand $v
                }
                default {
                    puts stderr "Unknown option to fake button $bname: $o"
                }
            }
        }

        label $bname -text $btext \
            -borderwidth $fake_btn_cfg(bwd) \
            -font $fake_btn_cfg(fnt)
        fake_btn_op $bname create $bcommand
        bind $bname <ButtonPress> [list fake_btn_op $bname press $bcommand]
        bind $bname <ButtonRelease> [list fake_btn_op $bname release $bcommand]
        bind $bname <Leave> [list fake_btn_op $bname leave $bcommand]

        # If this were to become a more general "fake button" implementation,
        # might want:
        #       more configurable options
        #       global command $bname to do flash / configure / invoke
        #       override "destroy" to remove fake_btn_state array entry
    }

    proc fake_btn_op {bname op bcommand} {
        global fake_btn_state fake_btn_cfg

        set doit 0

        switch -- $op {
            create {
                set fake_btn_state($bname) 0
            }
            press {
                set fake_btn_state($bname) 1
            }
            release {
                if {$fake_btn_state($bname)} {  
                    set doit 1
                }
                set fake_btn_state($bname) 0
            }
            leave {
                set fake_btn_state($bname) 0
            }
        }

        if {$fake_btn_state($bname)} {
            $bname configure \
                -foreground $fake_btn_cfg(afg) \
                -background $fake_btn_cfg(abg) \
                -relief $fake_btn_cfg(are)
        } else {
            $bname configure \
                -foreground $fake_btn_cfg(nfg) \
                -background $fake_btn_cfg(nbg) \
                -relief $fake_btn_cfg(nre)
        }

        if {$doit} {
            uplevel "#0" $bcommand
        }
    }
    set Button fake_btn
} else {
    set Button button
}

wm iconname . "sockptyr"
wm title . "sockptyr"
wm resizable . 0 0

# window layout:
#       left side: scrolling list of connections
#       right side: info about selected connection; and some global options

frame .conns
canvas .conns.can -width $listwidth \
    -height $winheight -yscrollcommand {.conns.sb set} \
    -scrollregion [list 0 0 $listwidth 0] -background $bgcolor
scrollbar .conns.sb -command {.conns.can yview}
pack .conns.can -side left
pack .conns.sb -side right -fill y
pack .conns -side left

frame .detail -width $detwidth -height $winheight
label .detail.l1 -text "sockptyr: details" -font lblfont -justify left
frame .detail.ubb
canvas .detail.div -width 8 -height 8
.detail.div create line -4096 4 4096 4 -fill black
frame .detail.lbb
$Button .detail.lbb.x -text "Exit" -command {exit 0}
frame .detail.m
label .detail.m.l1 -text "No selection" -font lblfont -justify left \
    -wraplength $detwidth
label .detail.m.l2 -text "" -font txtfont -justify left \
    -wraplength $detwidth
label .detail.m.l3 -text "" -font txtfont -justify left \
    -wraplength $detwidth
label .detail.m.l4 -text "" -font txtfont -justify left \
    -wraplength $detwidth

pack propagate .detail 0
pack .detail.l1 -side top -fill x
pack .detail.m.l1 .detail.m.l2 -side top -anchor w
pack .detail.m.l3 .detail.m.l4 -side top -anchor w
pack .detail.m -side top -fill both -expand 1
pack .detail.ubb -side top -fill x
pack .detail.div -side top -fill x
pack .detail.lbb.x -side left
pack .detail.lbb -side bottom -fill x
pack .detail -side right -fill both

proc badconfig {msg} {
    puts stderr "Bad hard coded configuration: $msg"
    .detail.m.l2 configure -text "Bad hard coded configuration"
    .detail.m.l3 configure -text $msg
    .detail.m.l4 configure -text ""
    vwait forever
}

## ## ## Load the sockptyr library

# The rationale for loading the library so late is that then you can see
# the GUI and the error message about loading the library, instead of
# having nothing come up.
update
if {[catch {load $sockptyr_library_path sockptyr} res]} {
    puts stderr "Failed to load sockptyr library from $sockptyr_library_path: $res"
    .detail.m.l2 configure -text "sockptyr library not loaded"
    .detail.m.l3 configure -text "error: $res"
    .detail.m.l4 configure -text ""
    vwait forever
}

set sockptyr_info(USE_INOTIFY) 0 ; # will be overwritten from [sockptyr info]
array set sockptyr_info [sockptyr info]

## ## ## Connection handling

# About how connection entries in .conns.can are tracked:
#   $conn_cfgs($label) identifies the label used in $config(...) for this
#       and possibly other connections
#   $conn_hdls($label) maps the unique label string to a "sockptyr" handle
#       or "" if it's not ok
#   $conn_tags($label) maps the unique label string to a tag in .conns.can
#   $conn_line1($label) maps the unique label string to descriptive text
#   $conn_line2($label) maps the unique label string to descriptive text
#   $conn_line3($label) maps the unique label string to descriptive text
#   $conn_deact($label) is code to run to cancel whatever action had been
#                       done on the connection, like when closing it
#                       or performing a contrary action
#   $conn_lord($label) is its position in the list (0, 1, 2, etc)
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

    global conns conn_cfgs conn_hdls conn_tags conn_desc conn_deact
    global conn_line1 conn_line2 conn_line3
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
    set conn_cfgs($conn) $label
    set conn_line3($conn) ""
    set conn_deact($conn) ""
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

    # Register handlers for things happening on the connection
    if {$conn_hdls($conn) ne ""} {
        sockptyr onclose $conn_hdls($conn) [list conn_onclose $conn]
        sockptyr onerror $conn_hdls($conn) [list conn_onerror $conn c]
    }

    # Create UI elements in .conns.can; positioned later.
    # tagging:
    #       $tag - all the stuff for this connection
    #       $tag.t - text label for the connection (left side)
    #       $tag.n - text note for the connection (right side)
    #       $tag.r - rectangle around the connection's stuff
    #       $tag.c - everything but $tag.r
    .conns.can create rectangle 0 0 0 0 \
        -fill $bgcolor -outline "" \
        -tags [list $tag $tag.r]
    .conns.can create text 0 0 \
        -font txtfont -fill $fgcolor -anchor nw \
        -text $conn -tags [list $tag $tag.t $tag.c]
    .conns.can create text $listwidth 0 \
        -font txtfont -fill $fgcolor -anchor ne \
        -text "" -tags [list $tag $tag.n $tag.c]
    .conns.can bind $tag <Button-1> [list conn_sel $conn]

    # record status
    if {$conn_hdls($conn) ne ""} {
        conn_record_status $conn "" ""
    }

    # Record this connection's existence & put the connections in order.
    # This could obviously be done more efficiently but there are many
    # inefficiencies around that are about as bad.
    lappend conns $conn
    set conns [lsort $conns]
    conn_pos
}

# conn_pos: Go through the connection list after it has changed, to
# reposition all connections.
proc conn_pos {} {
    global conns conn_tags listwidth bgcolor bgcolor2 conn_lord

    set y 0
    set i 0
    foreach conn $conns {
        set tag $conn_tags($conn)
        lassign [.conns.can bbox $tag.c] obx1 oby1 obx2 oby2
        .conns.can move $tag 0 [expr {$y - $oby1}]
        lassign [.conns.can bbox $tag.c] nbx1 nby1 nbx2 nby2
        .conns.can coords $tag.r 0 $nby1 $listwidth $nby2
        set conn_lord($conn) $i
        .conns.can itemconfigure $tag.r \
            -fill [expr {($conn_lord($conn) & 1) ? $bgcolor2 : $bgcolor}]
        set y [expr {$y + $nby2 - $nby1}]
        incr i
    }

    # and adjust the scrollbar
    .conns.can configure -scrollregion [list 0 0 $listwidth $y]
}

# conn_sel: Called to select a connection from the connection list.
# Parameters: unique connection label; or, empty string to deselect whatever's
# selected.
set conn_sel ""
proc conn_sel {conn} {
    puts stderr [list conn_sel $conn]

    global conn_sel bgcolor fgcolor conn_tags conn_lord
    global conn_line1 conn_line2 conn_line3 bgcolor bgcolor2

    if {$conn_sel ne ""} {
        # deselect the current one
        set tag $conn_tags($conn_sel)
        .conns.can itemconfigure $tag.r \
            -fill [expr {($conn_lord($conn_sel) & 1) ? $bgcolor2 : $bgcolor}]
        .conns.can itemconfigure $tag.c -fill $fgcolor
    }

    destroy .detail.ubb.if
    if {$conn eq ""} {
        # selecting nothing
        .detail.m.l1 configure -text "No selection"
        .detail.m.l2 configure -text ""
        .detail.m.l3 configure -text ""
        .detail.m.l4 configure -text ""
    } else {
        # selecting a particular connection
        set tag $conn_tags($conn)
        .detail.m.l1 configure -text $conn
        .detail.m.l2 configure -text $conn_line1($conn)
        .detail.m.l3 configure -text $conn_line2($conn)
        .detail.m.l4 configure -text $conn_line3($conn)
        .conns.can itemconfigure $tag.r -fill $fgcolor
        .conns.can itemconfigure $tag.c -fill $bgcolor
        frame .detail.ubb.if
        pack .detail.ubb.if -expand 1 -fill both

        # and buttons for it
        global config conn_cfgs conn_hdls Button
        set cfg $conn_cfgs($conn)
        for {set i 0} {[info exists config($cfg:button:$i:action)]} {incr i} {
            if {$conn_hdls($conn) eq ""} {
                # The connection doesn't really exist, is the button still
                # applicable?
                if {!([info exists config($cfg:button:$i:always)] &&
                      $config($cfg:button:$i:always))} {
                    # nope, skip it
                    continue
                }
            }
            set cmd [list $Button .detail.ubb.if.b$i]
            set cmdcmd $config($cfg:button:$i:action)
            lappend cmdcmd $cfg
            lappend cmdcmd $conn
            lappend cmd -command $cmdcmd
            if {[info exists config($cfg:button:$i:text)]} {
                lappend cmd -text $config($cfg:button:$i:text)
            }
            eval $cmd
            pack .detail.ubb.if.b$i -side left
        }
    }

    set conn_sel $conn
}
conn_sel ""

# conn_del: Remove a connection from the connection list.
proc conn_del {conn} {
    puts stderr [list conn_del $conn]

    global conns conn_sel conn_deact
    global conn_hdls conn_cfgs conn_tags
    global conn_line1 conn_line2 conn_line3 conn_lord

    if {$conn eq ""} return ; # shouldn't happen

    if {$conn_deact($conn) ne ""} {
        uplevel "#0" $conn_deact($conn)
        set conn_deact($conn) ""
    }

    if {$conn_sel eq $conn} {
        # This connection was selected; deselect it.
        conn_sel ""
    }

    # remove from $conns

    set i [lsearch -exact $conns $conn]
    if {$i >= 0} {
        set conns [lreplace $conns $i $i]
    }

    # remove from the GUI list of connections and from the various arrays

    .conns.can delete $conn_tags($conn)
    unset conn_tags($conn)
    unset conn_line1($conn)
    unset conn_line2($conn)
    unset conn_line3($conn)
    unset conn_deact($conn)
    if {$conn_hdls($conn) ne ""} {
        # close the connection, it isn't already
        sockptyr onclose $conn_hdls($conn)
        sockptyr onerror $conn_hdls($conn)
        sockptyr close $conn_hdls($conn)
    }
    unset conn_hdls($conn)
    unset conn_cfgs($conn)
    unset conn_lord($conn)

    # redraw the GUI list of connections
    
    conn_pos
}

# conn_record_status: Record connection status like linked or not open.
proc conn_record_status {conn long short} {
    global conn_line3 conn_sel conn_tags

    if {$long eq ""} {
        set long "One-sided"
    }

    set conn_line3($conn) "Status: $long"
    .conns.can itemconfigure $conn_tags($conn).n -text $short

    if {$conn_sel eq $conn} {
        # This connection was selected; reselect it for updated
        # information.
        conn_sel $conn
    }
}

# conn_action_close: Handle the GUI "close" button on a connection, to close
# it and remove it from the list.
#       $cfg = configuration label for the connection
#       $conn = full label for the connection
proc conn_action_close {cfg conn} {
    puts stderr [list conn_action_close $cfg $conn]
    conn_del $conn
}

# conn_action_loopback: Handle the GUI "loopback" button on a connection,
# to hook it up to itself.
#       $cfg = configuration label for the connection
#       $conn = full label for the connection
proc conn_action_loopback {cfg conn} {
    puts stderr [list conn_action_loopback $cfg $conn]

    global conn_deact conn_hdls

    # undo whatever was done before
    if {$conn_deact($conn) ne ""} {
        uplevel "#0" $conn_deact($conn)
        set conn_deact($conn) ""
    }
    if {$conn_hdls($conn) eq ""} {
        error "cannot do loopback on a connection that's closed"
    }
    sockptyr link $conn_hdls($conn) $conn_hdls($conn)
    conn_record_status $conn "Connected in loopback" "L"
}

# conn_action_ptyrun: Handle GUI "ptyrun" buttons (such as "Terminal") on
# a connection.  Opens a PTY and executes a process to run on it.
#       $cmd = shell command to run with limited "%" substitution
#       $statlong, $statshort = long & short connection status strings
#       $cfg = configuration label for the connection
#       $conn = full label for the connection
proc conn_action_ptyrun {cmd statlong statshort cfg conn} {
    puts stderr [list conn_action_ptyrun $cmd $statlong $statshort $cfg $conn]

    global conn_deact conn_hdls

    # undo whatever was done before
    if {$conn_deact($conn) ne ""} {
        uplevel "#0" $conn_deact($conn)
        set conn_deact($conn) ""
    }

    # get the PTY
    lassign [sockptyr open_pty] pty_hdl pty_path

    # Perform "%" substitution on cmd.  This could be faster than it is,
    # by using "string first" to skip over long stretches without "%", but
    # that would make the code more complicated.
    set cmd2 ""
    for {set i 0} {$i < [string length $cmd]} {incr i} {
        set ch [string index $cmd $i]
        if {$ch eq "%"} {
            # "%" character, substituted
            incr i
            set ch [string index $cmd $i]
            switch -- $ch {
                "%" {
                    # "%%" means "%"
                    append cmd2 "%"
                }
                "l" {
                    # "%l" subs in $conn (which is made sure to be safe
                    # text when it's created in "conn_add")
                    append cmd2 $conn
                }
                "p" {
                    # "%p" subs in the PTY path
                    append cmd2 $pty_path
                }
                default {
                    puts stderr "unknown % sequence in command, not running"
                    sockptyr close $pty_hdl
                    return
                }
            }
        } else {
            # normal character, unsubstituted
            append cmd2 $ch
        }
    }

    # Execute that command
    puts stderr [list about to execute: $cmd2]
    exec sh -c $cmd2 </dev/null >@stdout 2>@stderr

    # Linkage, status, tracking, and cleanup
    sockptyr link $conn_hdls($conn) $pty_hdl
    conn_record_status $conn "$statlong ($pty_path)" $statshort
    set conn_deact($conn) [list ptyrun_byebye $conn $pty_hdl]
    sockptyr onclose $pty_hdl [list ptyrun_byebye $conn $pty_hdl]
    sockptyr onerror $pty_hdl [list conn_onerror ${conn} p]
}

# conn_onclose: Run when a connection gets closed (and not by us).
#       $conn = full label for the connection
proc conn_onclose {conn} {
    puts stderr [list conn_onclose $conn]

    global conn_hdls conn_deact

    if {$conn_deact($conn) ne ""} {
        uplevel "#0" $conn_deact($conn)
        set conn_deact($conn) ""
    }

    if {$conn_hdls($conn) ne ""} {
        # get rid of the connection handle
        sockptyr onclose $conn_hdls($conn)
        sockptyr onerror $conn_hdls($conn)
        sockptyr close $conn_hdls($conn)
        set conn_hdls($conn) ""
    }

    conn_record_status $conn "Closed" "C"
}

# conn_onerror: Run when an error happens on a connection.
#       $conn = full label for the connection
#       $sub = for connections that have more than one fd, indicate the one
#       $ekws = error keywords, see sockptyr-tcl-api.txt
#       $emsg = textual error message
# Could do something fancy, for now it doesn't even display the error
# in the GUI, it just puts it on stderr.
proc conn_onerror {conn sub ekws emsg} {
    puts stderr [list conn_onerror $conn $sub $ekws $emsg]

    # see if some kind of disconnection is happening
    set discon 0
    foreach ekw $ekws {
        switch $ekw {
            "EIO" -
            "EPIPE" -
            "ECONNRESET" -
            "ESHUTDOWN" { set discon 1 }
        }
    }

    if {$discon} {
        if {$sub eq "c"} {
            # close the connection itself
            conn_onclose $conn
        } else {
            # cancel whatever it was doing
            global conn_deact

            if {$conn_deact($conn) ne ""} {
                uplevel "#0" $conn_deact($conn)
                set conn_deact($conn) ""
            }
        }
    }
    # XXX if an error comes in fast the GUI won't update
}

# ptyrun_byebye: Run when a connection set up with "conn_action_ptyrun"
# is ended for whetever reason, to clean up after it.
#       $conn = full label for the connection
#       $pty_hdl = handle for the PTY it's connected to
proc ptyrun_byebye {conn pty_hdl} {
    puts stderr [list ptyrun_byebye $conn $pty_hdl]

    global conn_hdls conn_deact

    set conn_deact($conn) ""
    sockptyr onclose $pty_hdl
    sockptyr link $conn_hdls($conn)
    sockptyr close $pty_hdl
    conn_record_status $conn "" ""

    # XXX this doesn't actually close the terminal
}

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
# and using array $_labels(...) temporarily.
array unset _labels
set labels [list]
foreach k [array names config] {
    lassign [split $k ":"] label lfield button bfield
    if {![info exists _labels($label)]} {
        lappend labels $label
        set _labels($label) 1
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

