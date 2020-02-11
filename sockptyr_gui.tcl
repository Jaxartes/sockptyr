#!/bin/sh
# sockptyr_gui.tcl
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

# the next line restarts using wish \
exec /usr/bin/wish "$0" ${1+"$@"}
# GUI for sockptyr: A Tk application that monitors for connections you
# want to hook up to, and gives you buttons for, e.g. starting terminal
# windows hooked up to them.

# dmsg -- emit a diagnostic message (if enabled)
proc dmsg {msg} {
    global config
    if {$config(verbosity)} {
        puts stderr $msg
    }
}

## ## ## Configuration

# Read configuration from a file, "sockptyr.cfg", in the same directory
# as the script.  It's actually a Tcl script itself, which builds the
# $config(...) array.  See "sockptyr.cfg.example" for an example config
# and documentation.

# some defaults
set config(verbosity) 0
set config(directory_retries) {250 500 1250}

# find & read that config file
set config_file_name [file join [file dirname [info script]] sockptyr.cfg]
puts stderr "sockptyr_gui: reading config file at $config_file_name"
source $config_file_name

# $sockptyr_library_path: File pathname to load the sockptyr library
# (compiled from sockptyr_core.c).
set sockptyr_library_path \
    [file join [file dirname [info script]] "sockptyr[info sharedlibextension]"]

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
set listwidth 320

# detwidth - list of detail display
set detwidth 384

# winheight - height of window
set winheight 448

# mark_half_size - half the size of the mark made by conn_action_mark
set mark_half_size 4

# listpad - padding around list items
set listpad 3

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
    puts stderr "sockptyr_gui: macOS aqua hack running"

    set fake_btn_cfg(nfg) black     ; # normal foreground color
    set fake_btn_cfg(nbg) white     ; # normal background color
    set fake_btn_cfg(nre) raised    ; # normal relief
    set fake_btn_cfg(afg) black     ; # actuated foreground color
    set fake_btn_cfg(abg) white     ; # actuated background color
    set fake_btn_cfg(are) sunken    ; # actuated relief
    set fake_btn_cfg(bwd) 5         ; # border width
    set fake_btn_cfg(fnt) lblfont   ; # font

    proc fake_btn {bname args} {
        global fake_btn_state fake_btn_cfg fake_btn_cmd

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

        set fake_btn_cmd($bname) $bcommand
        label $bname -text $btext \
            -borderwidth $fake_btn_cfg(bwd) \
            -font $fake_btn_cfg(fnt)
        fake_btn_op $bname create
        bind $bname <ButtonPress> [list fake_btn_op $bname press]
        bind $bname <ButtonRelease> [list fake_btn_op $bname release]
        bind $bname <Leave> [list fake_btn_op $bname leave]

        # If this were to become a more general "fake button" implementation,
        # might want:
        #       more configurable options
        #       global command $bname to do flash / configure / invoke
        #       override "destroy" to remove fake_btn_{state,cmd} array entries
    }

    proc fake_btn_op {bname op} {
        global fake_btn_state fake_btn_cfg fake_btn_cmd

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
            uplevel "#0" $fake_btn_cmd($bname)
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
$Button .detail.lbb.c -text "Clean" -command global_action_clean
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
pack .detail.lbb.c -side left
pack .detail.lbb -side bottom -fill x
pack .detail -side right -fill both

bind . <KeyPress-Up>       [list move_in_list - one]
bind . <KeyPress-Down>     [list move_in_list + one]
bind . <KeyPress-Prior>    [list move_in_list - page]
bind . <KeyPress-Next>     [list move_in_list + page]
bind . <KeyPress-Home>     [list move_in_list - all]
bind . <KeyPress-End>      [list move_in_list + all]

proc badconfig {msg} {
    puts stderr "Bad configuration: $msg"
    .detail.m.l2 configure -text "Bad configuration"
    .detail.m.l3 configure -text $msg
    .detail.m.l4 configure -text ""
    vwait forever
}

# move_in_list: Move around within the list of connections.  $dir is
# "-" or "+" for direction; $amt is "one", "page", or "all" for amount.
proc move_in_list {dir amt} {
    global conn_sel conn_byord conn_lord conn_count conn_tags

    lassign [.conns.can cget -scrollregion] rx1 ry1 rx2 ry2
    if {$conn_count < 1 || $ry2 <= $ry1} {
        # there are no connections
        break
    }

    # What connection is currently selected?  That'll be our starting point.
    # If there isn't one, just go to the first in the list
    if {$conn_sel eq ""} {
        if {[info exists conn_byord(0)]} {
            set cur_conn $conn_byord(0)
            set amt "no-move"
        } else {
            # there are no connections; do nothing
            return
        }
    } else {
        set cur_conn $conn_sel
    }
    set cur_pos $conn_lord($cur_conn)

    # Select a new connection as specified.
    set new_pos $cur_pos
    switch -- $amt {
        "one" {
            # move up or down by one list entry
            if {$dir eq "+"} {
                incr new_pos
            } else {
                incr new_pos -1
            }
        }
        "page" {
            # move up or down by about what you can see at once
            if {$dir eq "+"} {
                while {1} {
                    # single step
                    incr new_pos
                    if {$new_pos >= $conn_count - 1} {
                        break
                    }
                    # see where that gets us
                    set new_conn $conn_byord($new_pos)
                    set nct $conn_tags($new_conn)
                    lassign [.conns.can bbox $nct.c] bx1 by1 bx2 by2
                    lassign [.conns.can yview] vp1 vp2
                    set tp [expr {($by2 - $ry1) / double($ry2 - $ry1)}]
                    if {$tp > $vp2} {
                        break
                    }
                }
            } else {
                while {1} {
                    # single step
                    incr new_pos -1
                    if {$new_pos <= 0} {
                        break
                    }
                    # see where that gets us
                    set new_conn $conn_byord($new_pos)
                    set nct $conn_tags($new_conn)
                    lassign [.conns.can bbox $nct.c] bx1 by1 bx2 by2
                    lassign [.conns.can yview] vp1 vp2
                    set tp [expr {($by1 - $ry1) / double($ry2 - $ry1)}]
                    if {$tp < $vp1} {
                        break
                    }
                }
            }
        }
        "all" {
            # move to the top or bottom of the list
            if {$dir eq "+"} {
                set new_pos [expr {$conn_count - 1}]
            } else {
                set new_pos 0
            }
        }
    }

    # Avoid moving out of range.
    if {$new_pos < 0} {
        set new_pos 0
    } elseif {$new_pos >= $conn_count} {
        set new_pos [expr {$conn_count - 1}]
    }
    set new_conn $conn_byord($new_pos)

    # If the new connection is not visible, adjust scrollbar appropriately.
    lassign [.conns.can bbox $conn_tags($new_conn)] bx1 by1 bx2 by2
    lassign [.conns.can yview] vp1 vp2
    set tp1 [expr {($by1 - $ry1) / double($ry2 - $ry1)}]
    set tp2 [expr {($by2 - $ry1) / double($ry2 - $ry1)}]
    if {$tp2 > $vp2} {
        .conns.can yview moveto $tp1
    } elseif {$tp1 < $vp1} {
        .conns.can yview moveto [expr {$tp2 + $vp1 - $vp2}]
    }

    # Show details for the new connection.
    conn_sel $new_conn
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
#   $conn_wasok($label) is 1 if the connection was ok once, 0 if it
#       never was.  If $conn_hdls($label) has a handle then it's going
#       to be 1.  If $conn_hdls($label ) is "" this determines whether
#       the connection "failed" or was "closed".
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
#   $conn_byord($pos) == $label where $conn_lord($label) == $pos
#   $conn_count is the number of connections in the list
#   $conn_mark is the connection selected with "conn_action_link", if any

set conn_tags() 0
set conn_count 0
set conn_mark ""

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
    dmsg [list conn_add label $label ok $ok source $source he $he qual $qual]

    global conns conn_cfgs conn_hdls conn_tags conn_desc conn_deact
    global conn_wasok
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
    if {[info exists conn_tags($conn)] || $conn eq ""} {
        for {set i 0} {1} {incr i} {
            set conn2 [format %s.%lld $conn $i]
            if {![info exists conn_tags($conn2)]} {
                set conn $conn2
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
        set conn_wasok($conn) 1
    } else {
        set conn_hdls($conn) ""
        set conn_wasok($conn) 0
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
    #       $tag.m - synonymous with Mark if it's on this connection
    #       $tag.n - text note for the connection (right side)
    #       $tag.r - rectangle around the connection's stuff
    #       $tag.c - everything but $tag.r
    #       Mark - mark for conn_action_mark; not created here
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
    conn_record_status $conn "" ""

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
    global conns conn_tags listwidth bgcolor bgcolor2
    global conn_lord conn_byord conn_count conn_sel
    global listpad

    set y 0
    set i 0
    array unset conn_byord
    foreach conn $conns {
        set tag $conn_tags($conn)
        lassign [.conns.can bbox $tag.c] obx1 oby1 obx2 oby2
        .conns.can move $tag 0 [expr {$y - $oby1 + $listpad}]
        lassign [.conns.can bbox $tag.c] nbx1 nby1 nbx2 nby2
        set nby1 [expr {$nby1 - $listpad}]
        set nby2 [expr {$nby2 + $listpad}]
        .conns.can coords $tag.r 0 $nby1 $listwidth $nby2
        set conn_lord($conn) $i
        set conn_byord($i) $conn
        if {$conn_sel ne $conn} {
            .conns.can itemconfigure $tag.r \
                -fill [expr {($conn_lord($conn) & 1) ? $bgcolor2 : $bgcolor}]
        }
        set y [expr {$y + $nby2 - $nby1}]
        incr i
    }
    set conn_count $i

    # and adjust the scrollbar
    .conns.can configure -scrollregion [list 0 0 $listwidth $y]
}

# conn_sel: Called to select a connection from the connection list.
# Parameters: unique connection label; or, empty string to deselect whatever's
# selected.
set conn_sel ""
proc conn_sel {conn} {
    dmsg [list conn_sel $conn]

    global conn_sel bgcolor fgcolor conn_tags conn_lord
    global conn_line1 conn_line2 conn_line3 bgcolor bgcolor2

    if {$conn_sel ne ""} {
        # deselect the current one
        set tag $conn_tags($conn_sel)
        .conns.can itemconfigure $tag.r \
            -fill [expr {($conn_lord($conn_sel) & 1) ? $bgcolor2 : $bgcolor}]
        .conns.can itemconfigure $tag.c -fill $fgcolor
        .conns.can itemconfigure $tag.m -fill $fgcolor
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
        .conns.can itemconfigure $tag.m -fill $bgcolor
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
    dmsg [list conn_del $conn]

    global conns conn_sel conn_deact
    global conn_hdls conn_cfgs conn_tags conn_wasok
    global conn_line1 conn_line2 conn_line3 conn_lord conn_mark

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
        sockptyr close $conn_hdls($conn)
    }
    unset conn_hdls($conn)
    unset conn_cfgs($conn)
    unset conn_lord($conn)
    unset conn_wasok($conn)
    if {$conn_mark eq $conn} {
        set conn_mark ""
        .conns.can delete Mark
    }

    # redraw the GUI list of connections
    
    conn_pos
}

# conn_record_status: Record connection status like linked or not open.
proc conn_record_status {conn long short} {
    global conn_line3 conn_sel conn_tags conn_hdls conn_wasok

    if {$conn_hdls($conn) ne ""} {
        # connection is ok: if no status given it's "one sided"
        if {$long eq ""} {
            set long "One-sided"
        }
    } elseif {$conn_wasok($conn)} {
        # connection was ok but isn't any more: if no status given
        # it's "closed"
        if {$short eq ""} {
            set short "C"
        }
        if {$long eq ""} {
            set long "Closed"
        }
    } else {
        # connection was never ok: if no status given it's "failed"
        if {$short eq ""} {
            set short "!"
        }
        if {$long eq ""} {
            set long "Failed"
        }
    }

    set conn_line3($conn) "Status: $long"
    .conns.can itemconfigure $conn_tags($conn).n -text $short

    if {$conn_sel eq $conn} {
        # This connection was selected; reselect it for updated
        # information.
        conn_sel $conn
    }
}

# conn_action_remove: Get rid of the connection and remove it from our list.
#       $cfg = configuration label for the connection
#       $conn = full label for the connection
proc conn_action_remove {cfg conn} {
    dmsg [list conn_action_remove $cfg $conn]
    conn_del $conn
}

# conn_action_loopback: Handle the GUI "loopback" button on a connection,
# to hook it up to itself.
#       $cfg = configuration label for the connection
#       $conn = full label for the connection
proc conn_action_loopback {cfg conn} {
    dmsg [list conn_action_loopback $cfg $conn]

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
    dmsg [list conn_action_ptyrun $cmd $statlong $statshort $cfg $conn]

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
    dmsg [list about to execute: $cmd2]
    dmsg [list result: [sockptyr exec $cmd2]]

    # Linkage, status, tracking, and cleanup
    sockptyr link $conn_hdls($conn) $pty_hdl
    conn_record_status $conn "$statlong ($pty_path)" $statshort
    set conn_deact($conn) [list ptyrun_byebye $conn $pty_hdl]
    sockptyr onclose $pty_hdl [list ptyrun_byebye $conn $pty_hdl]
    sockptyr onerror $pty_hdl [list conn_onerror ${conn} p]
}

# conn_action_mark: Handle the GUI "mark" action on the connection, marking
# it for later use with conn_action_link.
#       $cfg = configuration label for the connection
#       $conn = full label for the connection
proc conn_action_mark {cfg conn} {
    dmsg [list conn_action_mark $cfg $conn]

    global conn_hdls conn_mark conn_tags mark_half_size fgcolor bgcolor

    set old_mark $conn_mark
    set conn_mark $conn
    .conns.can delete Mark

    lassign [.conns.can bbox $conn_tags($conn).t] tx1 ty1 tx2 ty2
    set mwx [expr {$tx2 + $mark_half_size}] ; # west corner of mark, X coord
    set mwy [expr {($ty1 + $ty2) / 2}]      ; # west corner of mark, Y coord
    .conns.can create polygon \
        $mwx $mwy \
        [expr {$mwx + $mark_half_size}] [expr {$mwy + $mark_half_size}] \
        [expr {$mwx + 2 * $mark_half_size}] $mwy \
        [expr {$mwx + $mark_half_size}] [expr {$mwy - $mark_half_size}] \
        -fill $bgcolor \
        -outline "" \
        -tags [list $conn_tags($conn) $conn_tags($conn).m Mark]
}

# conn_action_link: Handle the GUI "link" button on a connection,
# to hook it up to the one chosen with conn_action_mark.
#       $cfg = configuration label for the connection
#       $conn = full label for the connection
proc conn_action_link {cfg conn} {
    dmsg [list conn_action_link $cfg $conn]

    global conn_deact conn_hdls conn_mark

    # has a connection been marked?
    if {$conn_mark eq "" || ![info exists conn_hdls($conn_mark)]} {
        error "cannot link without marking a connection first"
    }

    # are both connections in the right state?
    foreach c [list $conn $conn_mark] {
        if {$conn_hdls($c) eq ""} {
            error "cannot link connections when one is closed"
        }
    }

    # undo anything done before on either connection
    foreach c [list $conn $conn_mark] {
        if {$conn_deact($c) ne ""} {
            uplevel "#0" $conn_deact($c)
            set conn_deact($c) ""
        }
    }

    # link them
    sockptyr link $conn_hdls($conn) $conn_hdls($conn_mark)
    conn_record_status $conn "Linked to $conn_mark" "L"
    conn_record_status $conn_mark "Linked to $conn" "L"

    # follow ups
    set conn_deact($conn) [list link_byebye $conn $conn_mark]
    set conn_deact($conn_mark) [list link_byebye $conn_mark $conn]
    sockptyr onclose $conn_hdls($conn) [list conn_onclose $conn]
    sockptyr onerror $conn_hdls($conn) [list conn_onerror $conn c]
    sockptyr onclose $conn_hdls($conn_mark) [list conn_onclose $conn_mark]
    sockptyr onerror $conn_hdls($conn_mark) [list conn_onerror $conn_mark c]

    set conn_mark ""
    .conns.can delete Mark
}

# conn_onclose: Run when a connection gets closed (and not by us).
#       $conn = full label for the connection
proc conn_onclose {conn} {
    dmsg [list conn_onclose $conn]

    global conn_hdls conn_deact conn_mark

    if {$conn_deact($conn) ne ""} {
        uplevel "#0" $conn_deact($conn)
        set conn_deact($conn) ""
    }

    if {$conn_hdls($conn) ne ""} {
        # get rid of the connection handle
        sockptyr close $conn_hdls($conn)
        set conn_hdls($conn) ""
        if {$conn_mark eq $conn} {
            set conn_mark ""
            .conns.can delete Mark
        }
    }

    conn_record_status $conn "" ""
}

# conn_onerror: Run when an error happens on a connection.
#       $conn = full label for the connection
#       $sub = since some connections might have more than one handle associated
#           with them, indicate which one it is:
#               c - the connection itself
#               p - a PTY linked to the connection
#       $ekws = error keywords, see sockptyr-tcl-api.txt
#       $emsg = textual error message
# Could do something fancy, for now it doesn't even display the error
# in the GUI, it just puts it on stderr.
proc conn_onerror {conn sub ekws emsg} {
    dmsg [list conn_onerror $conn $sub $ekws $emsg]

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
    # XXX a fast spew of errors can prevent the GUI from updating
}

# ptyrun_byebye: Run when a connection set up with "conn_action_ptyrun"
# is ended for whetever reason, to clean up after it.
#       $conn = full label for the connection
#       $pty_hdl = handle for the PTY it's connected to
proc ptyrun_byebye {conn pty_hdl} {
    dmsg [list ptyrun_byebye $conn $pty_hdl]

    global conn_hdls conn_deact

    set conn_deact($conn) ""
    sockptyr close $pty_hdl
    conn_record_status $conn "" ""
}

# link_byebye: Run when a connection set up with "conn_action_link"
# is ended for whatever reason, to clean up after it.
#       $conn = full label for the connection
#       $conn2 = full label for the connection it's linked to
proc link_byebye {conn conn2} {
    dmsg [list link_byebye $conn $conn2]

    global conn_hdls conn_deact

    set conn_deact($conn) ""
    conn_record_status $conn "" ""

    # and if $conn2 still really exists, deal with it too
    if {[info exists conn_deact($conn2)] && $conn_deact($conn2) ne ""} {
        uplevel "#0" $conn_deact($conn2)
        set conn_deact($conn2) ""
    }
}

# read_and_connect_dir: Read a directory and connect to any sockets in
# it that weren't seen in previous reads.  Used when "inotify" is not
# available; also to start "inotify" if available.
# Parameters:
#   $path -- pathname to the directory
#   $label -- source label from $config(...)
# Uses global $_racd_seen(...) to keep track of sockets it saw the last
# time through.  $_racd_seen($label) is a list, containing two entries
# for each socket seen last time on processing $label: the filename
# and... something else, doesn't matter.
proc read_and_connect_dir {path label} {
    global _racd_seen config sockptyr_info

    # trace message
    dmsg [list read_and_connect_dir path $path label $label]

    # get configuration
    set srccfg $config($label:source)
    set pollint [lindex $srccfg 2]
    if {[llength $srccfg] > 3} {
        set retries_list [lindex $srccfg 3]
    } else {
        set retries_list $config(directory_retries)
    }

    # bookkeeping for record of what we've already seen
    if {![info exists _racd_seen($label)]} {
        set _racd_seen($label) [list]
    }
    array set osockets $_racd_seen($label)

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
            connect_with_retries $fullpath $label directory $name $retries_list
        }
    }

    # bookkeeping for record of what we've already seen
    set _racd_seen($label) [array get nsockets]

    # start inotify, if possible; otherwise just schedule to re-scan
    # the directory a little later
    if {$sockptyr_info(USE_INOTIFY)} {
        set incmd [list read_and_connect_inotify $path $label $retries_list]
        if {[catch {sockptyr inotify $path IN_CREATE $incmd} msg]} {
            puts stderr "sockptyr inotify $path failed: $msg"
        } else {
            return
        }
    }

    after [expr {int(ceil($pollint * 1000.0))}] \
        [list read_and_connect_dir $path $label]
}

# read_and_connect_inotify: Run when "inotify" notifies us of a directory
# entry being added; see if it's a socket and if so connect to it.
# Parameters:
#   $path -- pathname to the directory
#   $label -- source label from $config(...)
#   $retries_list -- list of millisecond intervals for connection retries
#   $flags -- list of flags such as IN_CREATE
#   $cookie -- the API provides this to match related events together
#   $name -- name of file if any
proc read_and_connect_inotify {path label retries_list flags cookie name} {
    dmsg [list read_and_connect_inotify path $path label $label flags $flags cookie $cookie name $name]

    if {[lsearch -glob -nocase $flags *IGNORE] >= 0} {
        puts stderr "$path is gone and will no longer be monitored."
        # It's gone!  We won't get more events.  We could get rid of
        # this watch, but don't bother.
    }
    if {[lsearch -glob -nocase $flags *CREATE] >= 0} {
        set fullpath [file join $path $name]
        if {$name eq ""} {
            # huh?
            puts stderr "inotify gave us CREATE update w/o name"
            return
        }
        if {[string match ".*" $name]} {
            # hidden file, skip
            puts stderr "ignoring new file $name as it's hidden (a dotfile)"
            return
        }
        if {[catch {file type $fullpath} t] || $t ne "socket"} {
            # not a socket, skip
            puts stderr "ignoring new file $name as it's not a socket"
            return
        }

        # here's a socket
        connect_with_retries $fullpath $label directory $name $retries_list
    }
}

# connect_with_retries: Connect to a socket.  If it fails, retry at
# the given intervals until out of retries.  In either case add the
# socket to the GUI list.
proc connect_with_retries {fullpath label directory name retries_list} {
    dmsg [list connect_with_retries $fullpath $label $directory $name $retries_list]

    if {![catch {sockptyr connect $fullpath} hdl]} {
        # success
        conn_add $label 1 directory $hdl $name
    } elseif {[llength $retries_list]} {
        # try again
        after [lindex $retries_list 0] \
            [list connect_with_retries $fullpath $label $directory $name \
                [lrange $retries_list 1 end]]
    } else {
        # failure
        conn_add $label 0 directory $hdl $name
    }
}

# global_action_clean: Handles the "Clean" button which removes all
# closed and failed connections (but not one-sided ones, since you could
# very well want to reconnect to them).
proc global_action_clean {} {
    dmsg [list global_action_clean]
    global conns conn_hdls conn_cfgs
    foreach conn $conns {
        if {$conn_hdls($conn) eq ""} {
            conn_action_remove $conn_cfgs($conn) $conn
        }
    }
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
    if {[info exists config($label:source)] &&
        ![info exists _labels($label)]} {
        lappend labels $label
        set _labels($label) 1
    }
}
if {![llength $labels]} {
    # In this configuration, we'd never do anything; so just quit.
    puts stderr "$config_file_name doesn't specify any sources!"
    exit 1
}

# Go through the configured labels and their buttons and set them up.
foreach label [lsort $labels] {
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

            # Look what's in the directory, and prepare to continue
            # monitoring it, either through periodic polling or through inotify.
            read_and_connect_dir $path $label
        }
        default {
            badconfig "label '$label' unrecognized source '$source'"
            continue
        }
    }
}

