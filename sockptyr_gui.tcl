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
set sockptyr_library_path ./sockptyr.so

# $config(...): Configuration of what we monitor and what we do with it.
# An array with various keys and values as follows:
#       Identify each connection with a label $label
#           which is also used in display etc
#           the label actually used depends on the connection source
#           for "listen": $label:$counter
#           for "connect": $label
#           for "monitor": $label:[basename $filename]
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

set config(LISTY:source) {listen ./listysok}
set config(LISTY:button:Terminal:icon) ico_term
set config(LISTY:button:Terminal:ptyrun) {xterm -fn 8x16 -geometry 80x24 -fg cyan -bg black -cr cyan -sb -T "%l" -n "%l" -e picocom %p}
set config(LISTY:button:Loopback:icon) ico_back
set config(LISTY:button:Loopback:loopback) 1
set config(DIR:source) {directory ./sokdir 20.0}
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
        # not a fatal error, yet
    }
}

# lblfont - font for GUI labels
font create lblfont -family Times -size 18 -weight bold

## ## ## GUI

wm iconname . "sockptyr"
wm title . "sockptyr"
wm resizable . 0 0

# window layout:
#       left side: scrolling list of connections
#       right side: info about selected connection; and some global options

frame .conns
canvas .conns.can -width 160 -height 448 -yscrollcommand {.conns.sb set} \
    -scrollregion {0 0 160 1080}
scrollbar .conns.sb -command {.conns.can yview}
pack .conns.can -side left
pack .conns.sb -side right -fill y
pack .conns -side left
.conns.can create rect 10 10 30 30 -fill red
.conns.can create rect 130 10 150 30 -fill green
.conns.can create rect 10 1050 30 1070 -fill blue
.conns.can create rect 130 1050 150 1070 -fill purple

frame .detail
label .detail.l1 -text "sockptyr: details" -font lblfont -justify left
frame .detail.bbb
button .detail.bbb.x -text "Exit" -command {exit 0}

pack .detail.l1 -side top -fill x
pack .detail.bbb.x -side left
pack .detail.bbb -side bottom -fill x
pack .detail -side right -fill both

# XXX when building conn labels make sure they don't contain odd characters

## ## ## Load the sockptyr library

# The rationale for loading the library so late is that then you can see
# the GUI and the error message about loading the library, instead of
# having nothing come up.
update
if {[catch {load $sockptyr_library_path sockptyr} res]} {
    # XXX make this show up in the GUI
    puts stderr "Failed to load sockptyr library from $sockptyr_library_path: $res"
    vwait forever
}

## ## ## Now set things running

# XXX

