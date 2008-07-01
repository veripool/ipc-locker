# Normal run
make && script/lockerd --nofork --debug

# Performance profiling
make && perl -d:DProf script/lockerd --nofork --debug
make && ./locker_stress --host dualcore

# Performance test.  Use a IP number, not name
# $SCB/slrsh --parallel --hosts 'srv040 srv041 srv042 srv043 srv044 srv045 srv046 srv047 srv048 srv049 srv050 srv051 srv052 srv053 srv054 srv055 srv056 srv057 srv058 srv059'
make && nodist/locker_perf --persec=1000 --host=10.4.0.28 --runtime=10 --maxreq=1000 --holdlocks=1000

# Test locks
make && script/lockersh --lock foo --dhost ssp028 'echo "hi" && sleep 5 && echo done'

