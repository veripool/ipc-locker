# Normal run
make && script/lockerd --nofork --debug

# Performance profiling
make && perl -d:DProf script/lockerd --nofork --debug

# Performance test.  Use a IP number, not name
make && nodist/locker_perf --persec=1000 --host=10.4.0.28 --runtime=10 --maxreq=1000 --holdlocks=1000

# Test locks
make && script/lockersh --lock foo --dhost ssp028 'echo "hi" && sleep 5 && echo done'

