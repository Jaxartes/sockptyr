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

# $config: Configuration of what we monitor and what we do with it.
# A list containing one list for each thing we monitor; that list in
# turn contains:
#       Connection source:
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
#       Connection label:
#           1 element: $string
#           The label actually used is:
#               for "listen": $string:$counter
#               for "connect": $string
#               for "monitor": $string:$socketname
#       One or more things that the user can do with it; each is a
#       list containing:
#           How it's displayed:
#               2 elements: $icon $text
#               $icon is the name of an image defined within this program
#               for use as a graphical button; $text a textual alternative.
#           What to do when clicked:
#               To open a PTY and execute a program:
#                   2 elements: ptyrun $command
#                   runs shell command $command, with limited "%"
#                   substitution:
#                       %% - "%"
#                       %l - label
#                       %p - pty pathname
#               To link the connection to itself (loopback):
#                   1 element: loop
# XXX consider redoing this as an array
# XXX when building labels make sure they don't contain odd characters
set config {
    {listen ./listysok
     LISTY
     {ico_term Terminal
      ptyrun {xterm -fn 8x16 -geometry 80x24 -fg cyan -bg black -cr cyan -sb -T "%l" -n "%l" -e picocom %p}}
     {ico_back Loopback
      loop}}
    {directory ./sokdir
     DIR
     {ico_term Terminal
      ptyrun {xterm -fn 8x16 -geometry 80x24 -fg cyan -bg black -cr cyan -sb -T "%l" -n "%l" -e picocom %p}}
     {ico_back Loopback
      loop}}
}

## ## ## GUI

image create bitmap ico_term \
    -file /usr/include/X11/bitmaps/terminal

image create bitmap ico_back \
    -file /usr/include/X11/bitmaps/FlipHoriz 

## ## ## Load the sockptyr library

# The rationale for loading the library so late is that then you can see
# the GUI and the error message about loading the library, instead of
# having nothing come up.
update
if {[catch {load $sockptyr_library_path sockptyr} res]} {
    # XXX make this show up graphically & not clobber the program
    error "Failed to load sockptyr library from $sockptyr_library_path: $res"
}

## ## ## Now set things running

# XXX

