# IPC::Locker.pm -- distributed lock handler
# $Id$
# Wilson Snyder <wsnyder@wsnyder.org>
######################################################################
#
# Copyright 1999-2007 by Wilson Snyder.  This program is free software;
# you can redistribute it and/or modify it under the terms of either the GNU
# General Public License or the Perl Artistic License.
#
# This program is distributed in the hope that it will be useful,
# but WITHOUT ANY WARRANTY; without even the implied warranty of
# MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE.  See the
# GNU General Public License for more details.
#
######################################################################

=head1 NAME

IPC::Locker - Distributed lock handler

=head1 SYNOPSIS

  use IPC::Locker;

  my $lock = IPC::Locker->lock(lock=>'one_per_machine',
			       host=>'example.std.com',
			       port=>223);

  if ($lock->lock()) { something; }
  if ($lock->locked()) { something; }

  $lock->unlock();

=head1 DESCRIPTION

L<IPC::Locker> will query a remote lockerd server to obtain a lock around a
critical section.  When the critical section completes, the lock may be
returned.

This is useful for distributed utilities which run on many machines, and
cannot use file locks or other such mechanisms due to NFS or lack of common
file systems.

Multiple locks may be requested, in which case the first lock to be free
will be used.  Lock requests are serviced in a first-in-first-out order,
and the locker can optionally free locks for any processes that cease to
exist.

=over 4

=item new ([parameter=>value ...]);

Create a lock structure.

=item lock ([parameter=>value ...]);

Try to obtain the lock, return the lock object if successful, else undef.

=item locked ()

Return true if the lock has been obtained.

=item lock_name ()

Return the name of the lock.

=item unlock ()

Remove the given lock.  This will be called automatically when the object
is destroyed.

=item ping ()

Polls the server to see if it is up.  Returns true if up, otherwise undef.

=item ping_status ()

Polls the server to see if it is up.  Returns hash reference with {ok}
indicating if up, and {status} with status information.

=item break_lock ()

Remove current locker for the given lock.

=item owner ([parameter=>value ...]);

Returns a string of who has the lock or undef if not currently .  Note that
this information is not atomic, and may change asynchronously; do not use
this to tell if the lock will be available, to do that, try to obtain the
lock and then release it if you got it.

=back

=head1 PARAMETERS

=over 4

=item block

Boolean flag, true indicates wait for the lock when calling lock() and die
if a error occurs.  False indicates to just return false.  Defaults to
true.

=item destroy_unlock

Boolean flag, true indicates destruction of the lock variable should unlock
the lock, only if the current process id matches the pid passed to the
constructor.  Set to false if destruction should not close the lock, such
as when other children destroying the lock variable should not unlock the
lock.

=item family

The family of transport to use, either INET or UNIX.  Defaults to INET.

=item host

The name of the host containing the lock server.  It may also be a array
of hostnames, where if the first one is down, subsequent ones will be tried.
Defaults to value of IPCLOCKER_HOST or localhost.

=item port

The port number (INET) or name (UNIX) of the lock server.  Defaults to
IPCLOCKER_PORT environment variable, else 'lockerd' looked up via
/etc/services, else 1751.

=item lock

The name of the lock.  This may also be a reference to an array of lock names,
and the first free lock will be returned.

=item lock_list

Return a list of lock and lock owner pairs.  (You can assign this to a hash
for easier parsing.)

=item pid

The process ID that owns the lock, defaults to the current process id.

=item print_broke

A function to print a message when the lock is broken.  The only argument
is self.  Defaults to print a message if verbose is set.

=item print_obtained

A function to print a message when the lock is obtained after a delay.  The
only argument is self.  Defaults to print a message if verbose is set.

=item print_waiting

A function to print a message when the lock is busy and needs to be waited
for.  The first argument is self, second the name of the lock.  Defaults to
print a message if verbose is set.

=item print_down

A function to print a message when the lock server is unavailable.  The
first argument is self.  Defaults to a croak message.

=item timeout

The maximum time in seconds that the lock may be held before being forced
open, passed to the server when the lock is created.  Thus if the requester
dies, the lock will be released after that amount of time.  Zero disables
the timeout.  Defaults to 10 minutes.

=item user

Name to request the lock under, defaults to host_pid_user

=item autounlock

True to cause the server to automatically timeout a lock if the locking
process has died.  For the process to be detected, it must be on the same
host as either the locker client (the host making the lock call), or the
locker server.  Defaults false.

=item verbose

True to print messages when waiting for locks.  Defaults false.

=back

=head1 ENVIRONMENT

=over 4

=item IPCLOCKER_HOST

Hostname of L<lockerd> server, or colon separated list including backup
servers.  Defaults to localhost.

=item IPCLOCKER_PORT

The port number (INET) or name (UNIX) of the lock server.  Defaults to
'lockerd' looked up via /etc/services, else 1751.

=back

=head1 DISTRIBUTION

The latest version is available from CPAN and from L<http://www.veripool.com/>.

Copyright 1999-2007 by Wilson Snyder.  This package is free software; you
can redistribute it and/or modify it under the terms of either the GNU
Lesser General Public License or the Perl Artistic License.

=head1 AUTHORS

Wilson Snyder <wsnyder@wsnyder.org>

=head1 SEE ALSO

L<lockerd>, L<IPC::Locker::Server>

L<IPC::PidStat>, L<pidstat>, L<pidstatd>, L<pidwatch>

=cut

######################################################################

package IPC::Locker;
require 5.004;
require Exporter;
@ISA = qw(Exporter);

use Net::Domain;
use Socket;
use Time::HiRes qw(gettimeofday tv_interval);
use IO::Socket;

use IPC::PidStat;
use strict;
use vars qw($VERSION $Debug $Default_Port $Default_Family $Default_UNIX_port $Default_PidStat_Port);
use Carp;

######################################################################
#### Configuration Section

# Other configurable settings.
$Debug = 0;

$VERSION = '1.460';

######################################################################
#### Useful Globals

$Default_Port = ($ENV{IPCLOCKER_PORT}||'lockerd');	# Number (1751) or name to lookup in /etc/services
$Default_Port = 1751 if ($Default_Port !~ /^\d+$/ && !getservbyname ($Default_Port,""));
$Default_PidStat_Port = 'pidstatd';	# Number (1752) or name to lookup in /etc/services
$Default_PidStat_Port = 1752 if !getservbyname ($Default_PidStat_Port,"");
$Default_Family = 'INET';
$Default_UNIX_port = '/var/locks/lockerd';

######################################################################
#### Creator

sub new {
    @_ >= 1 or croak 'usage: IPC::Locker->new ({options})';
    my $proto = shift;
    my $class = ref($proto) || $proto;
    my $hostname = hostfqdn();
    my $self = {
	#Documented
	host=>($ENV{IPCLOCKER_HOST}||'localhost'),
	port=>$Default_Port,
	lock=>['lock'],
	timeout=>60*10, block=>1,
	pid=>$$,
	#user=>		# below
	hostname=>$hostname,
	autounlock=>0,
	destroy_unlock=>1,
	verbose=>$Debug,
	print_broke=>sub {my $self=shift; print "Broke lock from $_[0] at ".(scalar(localtime))."\n" if $self->{verbose};},
	print_obtained=>sub {my $self=shift; print "Obtained lock at ".(scalar(localtime))."\n" if $self->{verbose};},
	print_waiting=>sub {my $self=shift; print "Waiting for lock from $_[0] at ".(scalar(localtime))."\n" if $self->{verbose};},
	print_down=>undef,
	family=>$Default_Family,
	#Internal
	locked=>0,
	@_,};
    $self->{user} ||= hostfqdn() . "_".$self->{pid}."_" . ($ENV{USER} || "");
    foreach (_array_or_one($self->{lock})) {
	($_ !~ /\s/) or carp "%Error: Lock names cannot contain whitespace: $_\n";
    }
    bless $self, $class;
    return $self;
}

######################################################################
#### Static Accessors

sub hostfqdn {
    # Return hostname() including domain name
    return Net::Domain::hostfqdn();
}

######################################################################
#### Accessors

sub locked () {
    my $self = shift; ($self && ref($self)) or croak 'usage: $self->locked()';
    return $self if $self->{locked};
    return undef;
}

sub ping {
    my $self = shift;
    $self = $self->new(@_) if (!ref($self));
    my $ok = 0;
    eval {
	$self->_request("");
	$ok = 1;
    };
    return undef if !$ok;
    return ($self);
}

sub ping_status {
    my $self = shift;
    # Return OK and status message, for nagios like checks
    $self = $self->new(@_) if (!ref($self));
    my $ok = 0;
    my $start_time = [gettimeofday()];
    eval {
	$self->_request("");
	$ok = 1;
    };
    my $elapsed = tv_interval ( $start_time, [gettimeofday]);

    if (!$ok) {
	return ({ok=>undef,status=>"No response from lockerd on $self->{host}:$self->{port}"});
    } else {
	return ({ok=>1,status=>sprintf("%1.3f second response on $self->{host}:$self->{port}", $elapsed)});
    }
}

######################################################################
#### Constructor

sub lock {
    my $self = shift;
    $self = $self->new(@_) if (!ref($self));
    $self->_request("LOCK");
    croak $self->{error} if $self->{error};
    return ($self) if $self->{locked};
    return undef;
}

######################################################################
#### Destructor/Unlock

sub DESTROY () {
    my $self = shift; ($self && ref($self)) or croak 'usage: $self->DESTROY()';
    if ($self->{destroy_unlock} && $self->{pid} && $self->{pid}==$$) {
	$self->unlock();
    }
}

sub unlock {
    my $self = shift; ($self && ref($self)) or croak 'usage: $self->unlock()';
    return if (!$self->{locked});
    $self->_request("UNLOCK");
    croak $self->{error} if $self->{error};
    return ($self);
}

sub break_lock {
    my $self = shift; ($self) or croak 'usage: $self->break_lock()';
    $self = $self->new(@_) if (!ref($self));
    $self->_request("BREAK_LOCK");
    croak $self->{error} if $self->{error};
    return ($self);
}

######################################################################
#### User utilities: owner

sub owner {
    my $self = shift; ($self) or croak 'usage: $self->status()';
    $self = $self->new(@_) if (!ref($self));
    $self->_request ("STATUS");
    croak $self->{error} if $self->{error};
    print "Locker->owner = $self->{owner}\n" if $Debug;
    return $self->{owner};
}

sub lock_name {
    my $self = shift; ($self) or croak 'usage: $self->lock_name()';
    if (ref $self->{lock}
	&& $#{$self->{lock}}<1) {
	return $self->{lock}[0];
    } else {
	return $self->{lock};
    }
}

sub lock_list {
    my $self = shift;
    $self = $self->new(@_) if (!ref($self));
    $self->_request("LOCK_LIST");
    croak $self->{error} if $self->{error};
    return @{$self->{lock_list}};
}

######################################################################
######################################################################
#### Guts: Sending and receiving messages

sub _request {
    my $self = shift;
    my $cmd = shift;
  retry:

    # If adding new features, only send the new feature to the server
    # if the feature is on.  This allows for newer clients that don't
    # need to the new feature to still talk to older servers.
    my $req = ("user $self->{user}\n"
	       ."locks ".join(' ',@{_array_or_one($self->{lock})})."\n"
	       ."block ".($self->{block}||0)."\n"
	       ."timeout ".($self->{timeout}||0)."\n");
    $req.=    ("autounlock ".($self->{autounlock}||0)."\n"
	       ."pid $$\n"
	       ."hostname ".($self->{hostname})."\n"
	       ) if $self->{autounlock};
    $req.=    ("$cmd\n");
    print "REQ $req\n" if $Debug;

    my $fh;
    if ($self->{family} eq 'INET'){
	my @hostlist = ($self->{host});
	@hostlist = split (':', $self->{host}) if (!ref($self->{host}));
	@hostlist = @{$self->{host}} if (ref($self->{host}) eq "ARRAY");

	foreach my $host (@hostlist) {
	    print "Trying host $host\n" if $Debug;
	    $fh = IO::Socket::INET->new( Proto     => "tcp",
					 PeerAddr  => $host,
					 PeerPort  => $self->{port},
					 );
	    if ($fh) {
		if ($host ne $hostlist[0]) {
		    # Reorganize host list so whoever responded is first
		    # This is so if we grab a lock we'll try to return it to the same host
		    $self->{host} = [$host, @hostlist];
		}
		last;
	    }
	}
	if (!$fh) {
	    if (defined $self->{print_down}) {
		&{$self->{print_down}} ($self);
		return;
	    }
	    croak "%Error: Can't locate lock server on " . (join " or ", @hostlist), " $self->{port}\n"
		. "\tYou probably need to run lockerd\n$self->_request(): Stopped";
	}
    } elsif ($self->{family} eq 'UNIX') {
	$fh = IO::Socket::UNIX->new( Peer => $self->{port},
				     )
	    or croak "%Error: Can't locate lock server on $self->{port}.\n"
		. "\tYou probably need to run lockerd\n$self->_request(): Stopped";
    } else {
    	croak "IPC::Locker->_request(): No or wrong transport specified.";
    }
    
    $self->{lock_list} = [];

    print $fh "$req\nEOF\n";
    while (defined (my $line = <$fh>)) {
	chomp $line;
	next if $line =~ /^\s*$/;
	my @args = split /\s+/, $line;
	my $cmd = shift @args;
	print "RESP $line\n" if $Debug;
	$self->{locked} = $args[0] if ($cmd eq "locked");
	$self->{owner}  = $args[0] if ($cmd eq "owner");
	$self->{error}  = $args[0] if ($cmd eq "error");
	if ($cmd eq "lockname") {
	    $self->{lock}   = [$args[0]];
	    $self->{lock}   = $self->{lock}[0] if ($#{$self->{lock}}<1);  # Back compatible
	}
	if ($cmd eq 'lock' && @args == 2) {
	    push @{$self->{lock_list}}, @args;
 	}
	if ($cmd eq "autounlock_check") {
	    # See if we can break the lock because the lock holder ran on this same machine.
	    my ($lname,$lhost,$lpid) = @args;
	    if ($self->{hostname} eq $lhost) {
		if (IPC::PidStat::local_pid_doesnt_exist($lpid)) {
		    print "Autounlock_LOCAL $lname $lhost $lpid\n" if $Debug;
		    $self->break_lock(lock=>$self->{lock});
		    $fh->close();
		    goto retry;
		}
	    }
	}
	&{$self->{print_obtained}} ($self,@args)  if ($cmd eq "print_obtained");
	&{$self->{print_waiting}}  ($self,@args)  if ($cmd eq "print_waiting");
	&{$self->{print_broke}}    ($self,@args)  if ($cmd eq "print_broke");
	print "$1\n" if ($line =~ /^ECHO\s+(.*)$/ && $self->{verbose});  #debugging
    }
    # Note above break_lock also has prologue close
    $fh->close();
}

######################################################################

sub _array_or_one {
    return [$_[0]] if !ref $_[0];
    return $_[0];
}

sub colon_joined_list {
    my $item = shift;
    return $item if !ref $item;
    return (join ":",@{$item});
}

sub lock_name_list {
    my $self = shift;
    return colon_joined_list($self->{lock});
}

######################################################################
#### Package return
1;
