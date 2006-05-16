#!/usr/bin/perl -w
# $Id$
# DESCRIPTION: Perl ExtUtils: Type 'make test' to test this package
# Before `make install' is performed this script should be runnable with
# `make test'. After `make install' it should work as `perl test.pl'
#
# Copyright 1999-2006 by Wilson Snyder.  This program is free software;
# you can redistribute it and/or modify it under the terms of either the GNU
# General Public License or the Perl Artistic License.

use lib "./blib/lib";
use Test;
use strict;
use vars qw (%SLArgs $Serv_Pid);

BEGIN { plan tests => 3 }
BEGIN { require "t/test_utils.pl"; }

END { kill 'TERM', $Serv_Pid; }

#########################
# Server Constructor

use IPC::Locker::Server;
%SLArgs = (port=>socket_find_free(12345));

if ($Serv_Pid = fork()) {
} else {
    IPC::Locker::Server->new(%SLArgs)->start_server ();
    exit(0);
}
ok (1);
sleep(1); #Let server get established

#########################
# Test lockersh

{   print "lockersh:\n";
    my $rtn = `$PERL ./lockersh --dhost localhost --port $SLArgs{port} --lock lockersh_test echo OK`;
    chomp $rtn;
    print "returns: $rtn\n";
    ok($rtn eq "OK");
}

{   print "lockersh --locklist:\n";
    my $rtn = `$PERL ./lockersh --dhost localhost --port $SLArgs{port} --locklist`;
    ok(1);
}

