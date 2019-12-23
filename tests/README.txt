The "tests/" subdirectory contains various programs that could be
used when testing parts of "sockptyr."

Unless stated otherwise, they test the C code, not the full GUI.

Usage examples for each (run from the parent directory):
    sockptyr_tests_auto.tcl:
        make -f Makefile.linux test

    sockptyr_tests_bulk.tcl:
        read comments at top of file before using

    sockptyr_tests_churn.tcl:
        tclsh tests/sockptyr_tests_churn.tcl keep 5 10 run 500 hw cleanup hd
        see comments at top of file for more options

    sockptyr_tests_conl.tcl:
        set up sockets to connect to (named "tempsock1" and "tempsock2"
        in this example) using some other program, like "nc"
        tclsh tests/sockptyr_tests_conl.tcl tempsock1 tempsock2
        see comments at top of file for more options

    sockptyr_tests_ptyl.tcl:
        tclsh tests/sockptyr_tests_ptyl.tcl
        it'll display PTY pathnames
        you can connect to them with programs like "picocom"
        doesn't handle connection closure well
