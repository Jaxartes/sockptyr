load ./sockptyr.dylib
set lh [sockptyr listen ./sockptyr_test_env_l listener]
proc listener {hdl empty} {
    puts stderr [list new connection $hdl]
    sockptyr handler-storm $hdl
    monit $hdl
}
proc monit {hdl} {
    puts stderr [list hdl= $hdl ms= [clock milliseconds] info= [sockptyr info]]
    after 10000 [list monit $hdl]
}

vwait forever
