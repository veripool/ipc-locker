# $Id$
# DESCRIPTION: Perl ExtUtils: Type 'perl Makefile.PL' to create a Makefile for this package
#
# Copyright 1999-2008 by Wilson Snyder.  This program is free software;
# you can redistribute it and/or modify it under the terms of either the GNU
# General Public License or the Perl Artistic License.

require 5.005;
use ExtUtils::MakeMaker;
use Carp;

sub MY::postamble {
"
README: readme.texi
	-rm \$@
	makeinfo \$< --output \$@ --no-headers --no-validate

install::
	\@echo
	\@echo '-NOTE: You may want to'
	\@echo '-NOTE:      cp init.d/pidstatd init.d/lockerd  /etc/init.d'
	\@echo '-NOTE: And setup appropriate links in /etc/rc.d/rc*.d,'
	\@echo '-NOTE: and if using nagios,'
	\@echo '-NOTE:      cp nagios/check_pidstatd nagios/check_lockerd  /usr/lib/nagios/plugins'

install-here::
	make install

## Maintainer use:
preexist:
	test ! -r \$(HOME)/src/kits/\$(DISTVNAME).tar.gz
	test -s README

tag:
	svnorcvs tag  \$(DISTNAME)_\$(VERSION_SYM)

maintainer-diff:
	svnorcvs diff \$(DISTNAME)_\$(VERSION_SYM) 

maintainer-dist: preexist dist tag
	cp \$(DISTVNAME).tar.gz \$(HOME)/src/kits
	mv \$(DISTVNAME).tar.gz \$(HOME)/backpack

maintainer-clean: distclean
	-rm README Makefile

dist: distcheck
";
}

## Remember to upgrade version number!
WriteMakefile(
	      DISTNAME  => 'IPC-Locker',
	      NAME      => 'IPC::Locker',
	      AUTHOR	=> 'Wilson Snyder <wsnyder@wsnyder.org>',
	      ABSTRACT_FROM => 'lib/IPC/Locker.pm',
	      VERSION_FROM => 'lib/IPC/Locker.pm',
	      PREREQ_PM => {'Net::Domain' => 0,
			    'Pod::Usage' => 0,
			    'Time::HiRes' => 0,
			},
	      NO_META	=> 1,
	      EXE_FILES => [qw( script/lockerd script/lockersh
				script/pidstat script/pidstatd
				script/pidwatch
				script/uriexec )],
	      'dist'    => {COMPRESS => 'gzip -9f',
			    SUFFIX   => '.gz', 
			    DIST_DEFAULT => 'README all tardist',
			},
	      );

