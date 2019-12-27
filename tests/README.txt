The "tests/" subdirectory contains various programs that could be
used when testing parts of "sockptyr."

Unless stated otherwise, they test the C code, not the full GUI.

Usage examples for each (run from the parent directory):
    sockptyr_tests_auto.tcl:
        make -f Makefile.linux test

    sockptyr_tests_churn.tcl:
        tclsh tests/sockptyr_tests_churn.tcl keep 5 10 run 500 hd cleanup hd
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

    sockptyr_tests_bulk2.c:
        cc -g -Wall -o tests/sockptyr_tests_bulk2 tests/sockptyr_tests_bulk2.c -lm -lpthread
        wish sockptyr_gui.tcl
        ./tests/sockptyr_tests_bulk2 ./sockptyr_test_env_d 10 300.0 1.0 0.25
        use control-C to terminate it

    sockptyr.cfg.tests_bulk2:
        config file for use with sockptyr_tests_bulk2.c

    sockptyr_tests_cbulk2.tcl:
        tclsh tests/sockptyr_tests_cbulk2.tcl ./sockptyr.so ./sockptyr_test_env_d
        acts as the counterpart to sockptyr_tests_bulk2.c for tests
        not involving the GUI: it detects sockets, connects to them,
        and links them.  Needs inotify.
