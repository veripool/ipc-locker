# IPC::Locker.pm -- distributed lock handler
# $Id$
# Wilson Snyder <wsnyder@wsnyder.org>
######################################################################
#
# Copyright 1999-2006 by Wilson Snyder.  This program is free software;
# you can redistribute it and/or modify it under the terms of either the GNU
# General Public License or the Perl Artistic License.
#
# This program is distributed in the hope that it will be useful,
# but WITHOUT ANY WARRANTY; without even the implied warranty of
# MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE.  See the
# GNU General Public License for more details.
#
######################################################################

package IPC::PidStat;
require 5.004;

use IPC::Locker;
use Socket;
use Time::HiRes qw(gettimeofday tv_interval);
use IO::Socket;
use POSIX;

use strict;
use vars qw($VERSION $Debug);
use Carp;

######################################################################
#### Configuration Section

# Other configurable settings.
$Debug = 0;

$VERSION = '1.452';

######################################################################
#### Creator

sub new {
    # Establish the server
    @_ >= 1 or croak 'usage: IPC::PidStat->new ({options})';
    my $proto = shift;
    my $class = ref($proto) || $proto;
    my $self = {
	socket=>undef,	# IO::Socket handle of open socket
	tries=>5,
	# Documented
	port=>$IPC::Locker::Default_PidStat_Port,
	# Internal
	_host_ips => {},	# Resolved IP address of hosts
	@_,};
    bless $self, $class;
    return $self;
}

sub open_socket {
    my $self = shift;
    # Open the socket
    return if $self->{_socket_fh};
    $self->{_socket_fh} = IO::Socket::INET->new( Proto     => 'udp')
	or die "$0: %Error, socket: $!";
}

sub fh {
    my $self = shift;
    # Return socket file handle, for external select loops
    $self->open_socket();  #open if not already
    return $self->{_socket_fh};
}

sub pid_request {
    my $self = shift;
    my %params = (host=>'localhost',
		  pid=>$$,
		  @_);

    $self->open_socket();  #open if not already

    my $out_msg = "PIDR $params{pid}\n";

    my $ipnum = $self->{_host_ips}->{$params{host}};
    if (!$ipnum) {
	# inet_aton("name") calls gethostbyname(), which chats with the
	# NS cache socket and NIS server.  Too costly in a polling loop.
	$ipnum = inet_aton($params{host})
	    or die "%Error: Can't find host $params{host}\n";
	$self->{_host_ips}->{$params{host}} = $ipnum;
    }
    my $dest = sockaddr_in($self->{port}, $ipnum);
    $self->fh->send($out_msg,0,$dest);
}

sub recv_stat {
    my $self = shift;

    my $in_msg;
    $self->fh->recv($in_msg, 8192)
	or return undef;
    print "Got response $in_msg\n" if $Debug;
    if ($in_msg =~ /^EXIS (\d+) (\d+) (\S+)/) {  # PID server response
	my $pid=$1;  my $exists = $2;  my $hostname = $3;
	print "   Pid $pid Exists on $hostname? $exists\n" if $Debug;
	return ($pid, $exists, $hostname);
    } elsif ($in_msg =~ /^UNKN (\d+) (\s+) (\S+)/) {  # PID not determinate
	return undef;
    }
    return undef;
}

sub pid_request_recv {
    my $self = shift;
    my @params = @_;
    for (my $try=0; $try<$self->{tries}; $try++) {
	$self->pid_request(@params);
	my @recved;
	eval {
	    local $SIG{ALRM} = sub { die "Timeout\n"; };
	    alarm(1);
	    @recved = $self->recv_stat();
	    alarm(0);
	};
	alarm(0) if $@;
	return @recved if defined $recved[0];
    }
    return undef;
}   

######################################################################
#### Status checking

sub ping_status {
    my $self = shift;
    my %params = (pid => 1, 	# Init.
		  host => $self->{host},
		  @_,
		  );
    # Return OK and status message, for nagios like checks
    my $start_time = [gettimeofday()];
    my ($epid, $eexists, $ehostname) = eval {
	return $self->pid_request_recv(%params);
    };
    my $elapsed = tv_interval ( $start_time, [gettimeofday]);

    if (!$eexists) {
	return ({ok=>undef,status=>"No response from pidstatd on $self->{host}:$self->{port}"});
    } else {
	return ({ok=>1,status=>sprintf("%1.3f second response on $self->{host}:$self->{port}", $elapsed)});
    }
}

######################################################################
#### Utilities

sub local_pid_doesnt_exist {
    my $result = local_pid_exists(@_);
    # Return 0 if a pid exists, 1 if not, undef (or second argument) if unknown
    return undef if !defined $result;
    return !$result;
}

sub local_pid_exists {
    my $pid = shift;
    # Return 1 if a pid exists, 0 if not, undef (or second argument) if unknown
    # We can't just call kill, because if there's a different user running the
    # process, we'll get an error instead of a result.
    $! = undef;
    my $exists = (kill (0,$pid))?1:0;
    if ($!) {
	$exists = undef;
	$exists = 0 if $! == POSIX::ESRCH;
    }
    return $exists;
}

######################################################################
#### Package return
1;
=pod

=head1 NAME

IPC::PidStat - Process ID existence test

=head1 SYNOPSIS

  use IPC::PidStat;

  my $exister = new IPC::PidStat(
    port=>1234,
    );
  $exister->pid_request(host=>'foo', pid=>$pid)
  while (1) {  # Poll receiving callbacks
     my ($epid, $eexists, $ehostname) = $exister->recv_stat();
     print "Pid $epid ",($eexists?'exists':'dead'),"\n" if $ehostname;
  }

=head1 DESCRIPTION

L<IPC::PidStat> allows remote requests to be made to the
L<pidstatd>, to determine if a PID is running on the daemon's machine.

PidStat uses UDP, and as such results are fast but may be unreliable.
Furthermore, the pidstatd may not even be running on the remote machine,
so responses should never be required before an application program makes
progress.

=head1 METHODS

=over 4

=item new ([parameter=>value ...]);

Creates a new object for later use.  See the PARAMETERS section.

=item pid_request (host=>$host, pid=>$pid);

Sends a request to the specified host's server to see if the specified PID
exists.

=item pid_request_recv (host=>$host, pid=>$pid);

Calls pid_request and returns the recv_stat reply.  If the response fails
to return in one second, it is retried up to 5 times, then undef is
returned.

=item recv_stat()

Blocks waiting for any return from the server.  Returns undef if none is
found, or a 2 element array with the PID and existence flag.  Generally
this would be called inside a IO::Select loop.

=back

=head1 STATIC METHODS

=over 4

=item local_pid_doesnt_exist(<pid>)

Static call, not a method call.  Return 0 if a pid exists, 1 if not.
Return undef if it can't be determined.

=item local_pid_exists(<pid>)

Static call, not a method call.  Return 1 if a pid exists, 0 if not.
Return undef if it can't be determined.

=back

=head1 PARAMETERS

=over 4

=item port

The port number (INET) of the pidstatd server.  Defaults to 'pidstatd'
looked up via /etc/services, else 1752.

=back

=head1 DISTRIBUTION

The latest version is available from CPAN and from L<http://www.veripool.com/>.

Copyright 2002-2006 by Wilson Snyder.  This package is free software; you
can redistribute it and/or modify it under the terms of either the GNU
Lesser General Public License or the Perl Artistic License.

=head1 AUTHORS

Wilson Snyder <wsnyder@wsnyder.org>

=head1 SEE ALSO

L<IPC::Locker>, L<pidstat>, L<pidstatd>, L<pidwatch>

L<IPC::PidStat::Server>

=cut
######################################################################
