# $Id$
# DESCRIPTION: Perl ExtUtils: Type 'perl Makefile.PL' to create a Makefile for this package
#
# Copyright 1999-2006 by Wilson Snyder.  This program is free software;
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
	\@echo -NOTE: You may want to 'cp init.d/lockerd  /etc/init.d'
	\@echo -NOTE:                 'cp init.d/pidstatd /etc/init.d'
	\@echo -NOTE: And setup appropriate links in /etc/rc.d/rc3.d

install-here::
	make install

## Maintainer use:
preexist:
	test ! -r \$(HOME)/src/kits/\$(DISTVNAME).tar.gz

tag:
	cvs tag -F \$(DISTNAME)_\$(VERSION_SYM) .

maintainer-diff:
	cvs diff -r \$(DISTNAME)_\$(VERSION_SYM) 

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
	      NO_META	=> 1,
	      EXE_FILES => [qw( lockerd pidstatd pidwatch )],
	      'dist'    => {COMPRESS => 'gzip -9f',
			    SUFFIX   => '.gz', 
			    DIST_DEFAULT => 'README all tardist',
			},
	      );

