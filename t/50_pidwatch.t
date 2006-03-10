#!/usr/bin/perl -w
# $Id$
# DESCRIPTION: Perl ExtUtils: Type 'make test' to test this package
# Before `make install' is performed this script should be runnable with
# `make test'. After `make install' it should work as `perl test.pl'
#
# Copyright 1999-2003 by Wilson Snyder.  This program is free software;
# you can redistribute it and/or modify it under the terms of either the GNU
# General Public License or the Perl Artistic License.

use lib "./blib/lib";
use Test;
use strict;

BEGIN { plan tests => 3 }
BEGIN { require "t/test_utils.pl"; }

#########################

# We use init's pid (1), which had better be running :)
my $rtn = `$PERL ./pidwatch --pid 1 echo hello`;
ok(1);
chomp $rtn;
ok($rtn eq "hello");

my $nonexist_pid = 999999;  # not even legal
my $rtn2 = `$PERL ./pidwatch --pid $nonexist_pid echo never_executed`;
ok($rtn2 eq "");
