#!/usr/bin/perl -w
# DESCRIPTION: Perl ExtUtils: Type 'make test' to test this package
# Before `make install' is performed this script should be runnable with
# `make test'. After `make install' it should work as `perl test.pl'
#
# Copyright 1999-2009 by Wilson Snyder.  This program is free software;
# you can redistribute it and/or modify it under the terms of either the GNU
# Lesser General Public License Version 3 or the Perl Artistic License Version 2.0.

use lib "./blib/lib";
use Test;
use strict;
use vars qw (%SLArgs $Serv_Pid);

BEGIN { plan tests => 23 }
BEGIN { require "t/test_utils.pl"; }

END { kill 'TERM', $Serv_Pid; }

#########################
# Constructor

use IPC::Locker;
#$IPC::Locker::Debug=1;
#$IPC::Locker::Server::Debug=1;
ok(1);
print "IPC::Locker VERSION $IPC::Locker::VERSION\n";

#########################
# Server Constructor

use IPC::Locker::Server;
%SLArgs = (port=>socket_find_free(12345),
	   host=>'localhost');

if ($Serv_Pid = fork()) {
} else {
    IPC::Locker::Server->new(%SLArgs)->start_server ();
    exit(0);
}
ok (1);
sleep(1); #Let server get established

#########################
# User Constructor

my $lock = new IPC::Locker(%SLArgs,
			   timeout=>10,
			   print_down=>sub { die "\n%Error: Can't locate lock server\n"
						 . "\tServer must have not started in previous step\n";
					 }
			   );
ok ($lock);

# Lock obtain
ok ($lock->lock());

# Lock state
ok ($lock->locked());

# Lock owner
ok ($lock->owner());

# Lock obtain again, should still be locked
ok ($lock->lock());
ok ($lock->locked());

# Lock list
my @list = $lock->lock_list();
ok ($#list==1 && $list[0] eq 'lock' && $list[1]);

# Lock name
ok ($lock->lock_name() eq 'lock');

# Lock obtain and fail
ok (!defined( IPC::Locker->lock(%SLArgs, block=>0, user=>'alternate') ));

# Get lock by another name
my $lock2 = new IPC::Locker(%SLArgs,
			    timeout=>10,
			    lock=>[qw(lock lock2)],
			    autounlock=>1,
			    user=>'alt2',
			    );
ok ($lock2);

$lock2->lock();
ok (($lock2 && $lock2->locked()
     && $lock2->lock_name() eq "lock2"));

# Yet another dual lock obtain and fail
ok (!defined( IPC::Locker->lock(%SLArgs, block=>0, user=>'alt3',
				lock=>[qw(lock lock2)],) ));

# Get the lock under same owner, should "inherit" lock2's lock
my $lock3 =  new IPC::Locker(%SLArgs,
			     timeout=>10,
			     lock=>[qw(lock lock2)],
			     autounlock=>1,
			     user=>'alt2',
			     );
$lock3->lock();
ok ($lock3->lock());

# Lock release
ok ($lock->unlock());
ok (!$lock->locked());

# Lock release again, still unlocked
ok ($lock->unlock());
ok (!$lock->locked());

# Ping
ok ($lock->ping());

# Ping unknown host
ok (!(IPC::Locker->ping(host=>['no_such_host_as_this'],
			timeout=>1,
			)));

# Destructor
undef $lock;
ok (1);

#########################
{
    # Check errors get passed thru
    my $ret = eval {
	my $lock = IPC::Locker->lock (%SLArgs,
				      lock => "locker_subdie_test_$$");
        die "EXPECTED_DIE_in_EVAL";
    };
    my $eval_err = $@;
    ok ($eval_err && $eval_err =~ /EXPECTED_DIE_in_EVAL/);
}
