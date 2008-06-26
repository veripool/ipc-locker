#!/usr/bin/perl -w
# DESCRIPTION: Perl ExtUtils: Type 'make test' to test this package
# Before `make install' is performed this script should be runnable with
# `make test'. After `make install' it should work as `perl test.pl'
#
# Copyright 1999-2008 by Wilson Snyder.  This program is free software;
# you can redistribute it and/or modify it under the terms of either the GNU
# General Public License or the Perl Artistic License.

use lib "./blib/lib";
use Test;
use Sys::Hostname;
use strict;
use vars qw (%SLArgs $Serv_Pid);

BEGIN { plan tests => 17 }
BEGIN { require "t/test_utils.pl"; }

END { kill 'TERM', $Serv_Pid; }

#########################
# Constructor

use IPC::PidStat;
$IPC::PidStat::Debug=1;
ok(1);
print "IPC::PidStat VERSION $IPC::PidStat::VERSION\n";

#########################
# Static checks
ok (IPC::PidStat::local_pid_exists($$));
ok (!IPC::PidStat::local_pid_doesnt_exist($$));

#########################
# Server Constructor

use IPC::PidStat::PidServer;
%SLArgs = (port=>socket_find_free(12345));

if ($Serv_Pid = fork()) {
} else {
    IPC::PidStat::PidServer->new(%SLArgs)->start_server ();
    exit(0);
}
ok (1);
sleep(1); #Let server get established

#########################
# User Constructor

my $exister = new IPC::PidStat
    (%SLArgs,
     );
ok ($exister);

# Send request and check return
# These will (probably) use the local path, not the daemon
ok (check_stat($exister, 'localhost', 1234));

ok (check_stat($exister, 'localhost', 66666));

ok (check_stat($exister, 'localhost', $$));

# Send request and check return
# These will use the remote path
$IPC::PidStat::Hostname = 'non matching host name';  # Hack so we go remotely

ok (check_stat($exister, hostname(), 1234));

ok (check_stat($exister, hostname(), 66666));

ok (check_stat($exister, hostname(), $$));


# Destructor
undef $exister;
ok (1);

#########################
# pidwatch

# We use init's pid (1), which had better be running :)
{   print "pidwatch ok:\n";
    my $rtn = run_rtn("$PERL script/pidwatch --port $SLArgs{port} --pid 1 echo hello");
    ok(1);
    ok($rtn eq "hello");
}

{   print "pidwatch fail:\n";
    my $nonexist_pid = 999999;  # not even legal
    my $rtn = run_rtn("$PERL script/pidwatch --port $SLArgs{port} --pid $nonexist_pid \"sleep 1 ; echo never_executed\"");
    ok($rtn eq "");
}

{   print "pidwatch immediate exit:\n";
    my $rtn = run_rtn("$PERL script/pidwatch --port $SLArgs{port} --pid 1 --foreground $$");
    ok(1);
}

#########################
# Nagios script check

print "check_pidstat:\n";
if (!-d "/usr/lib/nagios/plugins") {
    skip("nagios not installed (harmless)",1);
} else {
    # Note we may not be running as root, so need to check $$, not init.
    my $rtn = run_rtn("$PERL nagios/check_pidstatd --port $SLArgs{port} --pid $$");
    ok($rtn =~ /OK/);
}

######################################################################

sub check_stat {
    my $exister = shift;
    my $host = shift;
    my $pid = shift;

    my $tries = 5;   # Number of messages to send.  We'll hope one gets
    # through to the server.  Since it's the local host, that seems almost
    # certain.

    my $pid_pre_exists = kill(0,$pid);
    my @recved = $exister->pid_request_recv(pid=>$pid,host=>$host);
    my $pid_post_exists = kill(0,$pid);  # Test again, may have changed state when request in flight.
    if (!defined $recved[0]) {
	warn "\n%Error: Null response for pid $pid: @recved,";
	warn "%Error: Perhaps you forgot to './pidstatd &' for this test?\n";
	return 0;
    } elsif ($recved[0]!=$pid) {
	warn "%Error: Bad PID response for pid $pid: @recved,";
	return 0;
    } elsif ($recved[1]!=$pid_pre_exists && $recved[1]!=$pid_post_exists) {
	warn "%Error: Bad Exists for pid $pid: @recved,";
	return 0;
    }
    return 1;
}
