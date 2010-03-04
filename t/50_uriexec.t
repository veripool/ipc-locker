#!/usr/bin/perl -w
# DESCRIPTION: Perl ExtUtils: Type 'make test' to test this package
# Before `make install' is performed this script should be runnable with
# `make test'. After `make install' it should work as `perl test.pl'
#
# Copyright 2007-2010 by Wilson Snyder.  This program is free software;
# you can redistribute it and/or modify it under the terms of either the GNU
# Lesser General Public License Version 3 or the Perl Artistic License Version 2.0.

use Test;
use strict;

BEGIN { plan tests => 2 }
BEGIN { require "t/test_utils.pl"; }

#########################

my $cmd = `$PERL script/uriexec echo %27Hello+%57orld%21%27`;
print "Got $cmd\n";
ok(1);
ok($cmd =~ /Hello World!/);

