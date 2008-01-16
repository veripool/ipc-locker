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

IPC::Locker::Server - Distributed lock handler server

=head1 SYNOPSIS

  use IPC::Locker::Server;

  IPC::Locker::Server->start_server(port=>1234,);

=head1 DESCRIPTION

L<IPC::Locker::Server> provides the server for the IPC::Locker package.

=over 4

=item start_server ([parameter=>value ...]);

Starts the server.  Does not return.

=back

=head1 PARAMETERS

=over 4

=item family

The family of transport to use, either INET or UNIX.  Defaults to INET.

=item port

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

L<IPC::Locker>, L<lockerd>

=cut

######################################################################

package IPC::Locker::Server;
require 5.004;
require Exporter;
@ISA = qw(Exporter);

use IPC::Locker;
use Socket;
use IO::Socket;
use IO::Poll qw(POLLIN POLLOUT POLLERR POLLHUP POLLNVAL);
use Time::HiRes;

use IPC::PidStat;
use strict;
use vars qw($VERSION $Debug %Locks %Clients $Poll $Interrupts $Hostname $Exister);
use Carp;

######################################################################
#### Configuration Section

# Other configurable settings.
$Debug = 0;

$VERSION = '1.472';
$Hostname = IPC::Locker::hostfqdn();

######################################################################
#### Globals

# All held locks
%Locks = ();
our $_Client_Num = 0;  # Debug use only

######################################################################
#### Creator

sub new {
    # Establish the server
    @_ >= 1 or croak 'usage: IPC::Locker::Server->new ({options})';
    my $proto = shift;
    my $class = ref($proto) || $proto;
    my $self = {
	#Documented
	port=>$IPC::Locker::Default_Port,
	family=>$IPC::Locker::Default_Family,
	@_,};
    bless $self, $class;
    my $param = {@_};
    if (defined $param->{family} && $param->{family} eq 'UNIX'
	&& !exists($param->{port})) {
    	$self->{port} = $IPC::Locker::Default_UNIX_port;
    }
    return $self;
}

sub start_server {
    my $self = shift;

    # Open the socket
    print "Listening on $self->{port}\n" if $Debug;
    my $server;
    if ($self->{family} eq 'INET') {
    	$server = IO::Socket::INET->new( Proto     => 'tcp',
					 LocalPort => $self->{port},
					 Listen    => SOMAXCONN,
					 Reuse     => 1)
	    or die "$0: Error, socket: $!";
    } elsif ($self->{family} eq 'UNIX') {
    	$server = IO::Socket::UNIX->new(Local => $self->{port},
					Listen    => SOMAXCONN,
					Reuse     => 1)
	    or die "$0: Error, socket: $!\n port=$self->{port}=";
	$self->{unix_socket_created}=1;
    } else {
    	die "IPC::Locker::Server:  What transport do you want to use?";
    }
    $Poll = IO::Poll->new();
    $Poll->mask($server => (POLLIN | POLLERR | POLLHUP | POLLNVAL));

    $Exister = IPC::PidStat->new();
    my $exister_fh = $Exister->fh;  # Avoid method calls, to accelerate things
    $Poll->mask($exister_fh => (POLLIN | POLLERR | POLLHUP | POLLNVAL));

    %Clients = ();
    #$SIG{ALRM} = \&sig_alarm;
    $SIG{INT}= \&sig_INT;
    $SIG{HUP}= \&sig_INT;
    
    while (!$Interrupts) {
	print "Pre-Poll $!\n" if $Debug;
	$! = 0;
	my (@r, @w, @e);

	my $timeout = ((scalar keys %Locks) ? 10 : 2000);
    	my $npolled = $Poll->poll($timeout); 
	if ($npolled>0) {
	    @r = $Poll->handles(POLLIN);
	    @e = $Poll->handles(POLLERR | POLLHUP | POLLNVAL);
	    #@w = $Poll->handles(POLLOUT);
	}
	print "Poll $npolled Locks=",(scalar keys %Locks),": $#r $#w $#e $!\n" if $Debug;
        foreach my $fh (@r) {
            if ($fh == $server) {
        	# Create a new socket
        	my $clientfh = $server->accept;
        	$Poll->mask($clientfh => (POLLIN | POLLERR | POLLHUP | POLLNVAL));
		print $clientfh "HELLO\n" if $Debug;
		#
		my $clientvar = {socket=>$clientfh,
				 input=>'',
				 inputlines=>[],
			     };
		$clientvar->{client_num} = $_Client_Num++ if $Debug;
		$Clients{$clientfh}=$clientvar;
	    } elsif ($fh == $exister_fh) {
		exist_traffic();
	    } else {
		my $data = '';
		my $rc = recv($fh, $data, 1000, 0);
		if ($data eq '') {
        	    # we have finished with the socket
		    delete $Clients{$fh};
        	    $Poll->remove($fh);
        	    $fh->close;
 		} else {
		    my $line = $Clients{$fh}->{input}.$data;
		    my @lines = split /\n/, $line;
		    if ($line =~ /\n$/) {
		    	$Clients{$fh}->{input}='';
			print "Nothing Left\n" if $Debug;
		    } else {
		    	$Clients{$fh}->{input}=pop @lines;
			print "Left: ".$Clients{$fh}->{input}."\n" if $Debug;
		    }
		    client_service($Clients{$fh}, \@lines);
		}
	    }
	}
	foreach my $fh (@e) {
	    # we have finished with the socket
	    delete $Clients{$fh};
	    $Poll->remove($fh);
	    $fh->close;
        }
	$self->recheck_locks();
    }
    print "Loop end\n" if $Debug;
}

######################################################################
######################################################################
#### Client servicing

sub client_service {
    my $clientvar = shift || die;
    my $linesref = shift;
    # Loop getting commands from a specific client
    print "$clientvar->{client_num}: REQS $clientvar->{socket}\n" if $Debug;
    
    if (defined $clientvar->{inputlines}[0]) {
	print "$clientvar->{client_num}: handling pre-saved lines\n" if $Debug;
	$linesref = [@{$clientvar->{inputlines}}, @{$linesref}];
	$clientvar->{inputlines} = [];  # Zap, in case we get called recursively
    }

    # We may return before processing all lines, thus the lines are
    # stored in the client variables
    foreach my $line (@{$linesref}) {
	print "$clientvar->{client_num}: REQ $line\n" if $Debug;
	my ($cmd,@param) = split /\s+/, $line;  # We rely on the newline to terminate the split
	if ($cmd) {
	    # Variables
	    if ($cmd eq 'user') {		$clientvar->{user} = $param[0]; }
	    elsif ($cmd eq 'locks') {		$clientvar->{locks} = [@param]; }
	    elsif ($cmd eq 'block') {		$clientvar->{block} = $param[0]; }
	    elsif ($cmd eq 'timeout') {		$clientvar->{timeout} = $param[0]; }
	    elsif ($cmd eq 'autounlock') {	$clientvar->{autounlock} = $param[0]; }
	    elsif ($cmd eq 'hostname') {	$clientvar->{hostname} = $param[0]; }
	    elsif ($cmd eq 'pid') {		$clientvar->{pid} = $param[0]; }

	    # Frequent Commands
	    elsif ($cmd eq 'UNLOCK') {
		client_unlock ($clientvar);
	    }
	    elsif ($cmd eq 'LOCK') {
		my $wait = client_lock ($clientvar);
		print "$clientvar->{client_num}: Wait= $wait\n" if $Debug;
		last if $wait;
	    }
	    elsif ($cmd eq 'EOF') {
		client_close ($clientvar);
		undef $clientvar;
		last; 
	    }

	    # Infrequent commands
	    elsif ($cmd eq 'STATUS') {
		client_status ($clientvar);
	    }
	    elsif ($cmd eq 'BREAK_LOCK') {
		client_break  ($clientvar);
	    }
	    elsif ($cmd eq 'LOCK_LIST') {
		client_lock_list ($clientvar);
	    }
	    elsif ($cmd eq 'RESTART') {
		die "restart";
	    }
	}
	# Commands
    }

    # Save any non-processed lines (from 'last') for next time
    $clientvar->{inputlines} = $linesref;
}

sub client_close {
    my $clientvar = shift || die;
    if ($clientvar->{socket}) {
	delete $Clients{$clientvar->{socket}};
	$Poll->remove($clientvar->{socket});
	$clientvar->{socket}->close();
    }
    $clientvar->{socket} = undef;
}

sub client_status {
    # Send status of lock back to client
    my $clientvar = shift || die;
    my @totry = ($clientvar->{lock});
    @totry = @{$clientvar->{locks}} if !defined $clientvar->{lock};
    $clientvar->{locked} = 0;
    $clientvar->{owner} = "";
    my $send = "";
    foreach my $lockname (@totry) {
	my $locki = locki_lookup ($lockname);
	$clientvar->{locked} = ($locki->{owner} eq $clientvar->{user})?1:0;
	$clientvar->{owner} = $locki->{owner};
	$clientvar->{lock} = $locki->{lock};
	if ($clientvar->{locked} && $clientvar->{told_locked}) {
	    $clientvar->{told_locked} = 0;
	    $send .= "print_obtained\n";
	}
	last if $clientvar->{locked};
    }

    $send .= "owner $clientvar->{owner}\n";
    $send .= "locked $clientvar->{locked}\n";
    $send .= "lockname $clientvar->{lock}\n" if $clientvar->{locked};
    $send .= "error $clientvar->{error}\n" if $clientvar->{error};
    $send .= "\n\n";  # End of group.  Some day we may not always send EOF immediately
    return client_send ($clientvar, $send);
}

sub client_lock_list {
    my $clientvar = shift || die;
    print "$clientvar->{client_num}: Locklist!\n" if $Debug;
    while (my ($lockname, $lock) = each %Locks) {
	if (!$lock->{locked}) {
	    print "$clientvar->{client_num}: Note unlocked lock $lockname\n" if $Debug;
	    next;
	}
	client_send ($clientvar, "lock $lockname $lock->{owner}\n");
    }
    return client_send ($clientvar, "\n\n");
}
 
sub client_lock {
    # Client wants this lock, return true if delayed transaction
    my $clientvar = shift || die;
    # Look for a free lock
  trial:  # We only have one trial, but the loop lets us 'last' out of it.
    while (1) {
	# Try all locks
	foreach my $lockname (@{$clientvar->{locks}}) {
	    print "$clientvar->{client_num}: **try1 $lockname\n" if $Debug;
	    my $locki = locki_lookup ($lockname);
	    # Try to cleanup existing lock
	    _recheck_lock($locki, undef);
	    # Already locked by this guy?
	    last trial if ($locki->{owner} eq $clientvar->{user} && $locki->{locked});
	    # Attempt to assign to us
	    if (!$locki->{locked}) {
		push @{$locki->{waiters}}, $clientvar;
		locki_lock($locki);
		#print "$clientvar->{client_num}: nl $lockname a $locki->{lock} b $clientvar->{lock}\n";
		last trial if ($locki->{owner} eq $clientvar->{user});
	    }
	}
	# All locks busy
	last trial if (!$clientvar->{block});
	# It's busy, wait for them all
	my $first_locki = undef;
	foreach my $lockname (@{$clientvar->{locks}}) {
	    print "$clientvar->{client_num}: **try2 $lockname\n" if $Debug;
	    my $locki = locki_lookup ($lockname);
	    if ($locki->{locked}) {
		$first_locki = $locki;
		push @{$locki->{waiters}}, $clientvar;
		if ($locki->{autounlock} && $clientvar->{autounlock}) {
		    client_send ($clientvar, "autounlock_check $locki->{lock} $locki->{hostname} $locki->{pid}\n");
		}
	    }
	}
	# Tell the user
	if (!$clientvar->{told_locked} && $first_locki) {
	    $clientvar->{told_locked} = 1;
	    client_send ($clientvar, "print_waiting $first_locki->{owner}\n");
	}
	# Either need to wait for timeout, or someone else to return key
	return 1;	# Exit loop and check if can lock later
    }
    client_status ($clientvar);
    0;
}

sub client_break {
    my $clientvar = shift || die;
    foreach my $lockname (@{$clientvar->{locks}}) {
	my $locki = locki_lookup ($lockname);
	if ($locki && $locki->{locked}) {
	    print "$clientvar->{client_num}: broke lock   $locki->{locks} User $clientvar->{user}\n" if $Debug;
	    client_send ($clientvar, "print_broke $locki->{owner}\n");
	    locki_unlock ($locki);
	}
    }
    client_status ($clientvar);
}

sub client_unlock {
    # Client request to unlock the given lock
    my $clientvar = shift || die;
    foreach my $lockname (@{$clientvar->{locks}}) {
	my $locki = locki_lookup ($lockname);
	if ($locki->{owner} eq $clientvar->{user}) {
	    print "$clientvar->{client_num}: Unlocked   $locki->{lock} User $clientvar->{user}\n" if $Debug;
	    locki_unlock ($locki);
	} else {
	    # Doesn't hold lock but might be waiting for it.
	    print "$clientvar->{client_num}: Waiter count: ".$#{$locki->{waiters}}."\n" if $Debug;
	    for (my $n=0; $n <= $#{$locki->{waiters}}; $n++) {
		if ($locki->{waiters}[$n]{user} eq $clientvar->{user}) {
		    print "$clientvar->{client_num}: Dewait     $locki->{lock} User $clientvar->{user}\n" if $Debug;
		    splice @{$locki->{waiters}}, $n, 1;
		}
	    }
	}
    }
    client_status ($clientvar);
}

sub client_send {
    # Send a string to the client, return 1 if success
    my $clientvar = shift || die;
    my $msg = shift;

    my $clientfh = $clientvar->{socket};
    return 0 if (!$clientfh);
    print "$clientvar->{client_num}: RESP $clientfh"
	.join("\n$clientvar->{client_num}: RES  ",split(/\n/,"\n$msg")),"\n" if $Debug;

    $SIG{PIPE} = 'IGNORE';
    my $status = eval { send $clientfh,$msg,0; };
    if (!$status) {
	warn "client_send hangup $? $! $status $clientfh " if $Debug;
	client_close ($clientvar);
	return 0;
    }
    return 1;
}

######################################################################
######################################################################
#### Alarm handler

sub sig_INT {
    $Interrupts++;
    #$SIG{INT}= \&sig_INT;
    0;
}

sub alarm_time {
    # Compute alarm interval and set
    die "Dead code\n";
    my $time = fractime();
    my $timelimit = undef;
    foreach my $locki (values %Locks) {
	if ($locki->{locked} && $locki->{timelimit}) {
	    $timelimit = $locki->{timelimit} if
		(!defined $timelimit
		 || $locki->{timelimit} <= $timelimit);
	}
    }
    return $timelimit ? ($timelimit - $time + 1) : 0;
}

sub fractime {
    my ($time, $time_usec) = Time::HiRes::gettimeofday();
    return $time + $time_usec * 1e-6;
}

######################################################################
######################################################################
#### Exist traffic

sub exist_traffic {
    # Handle UDP responses from our $Exister->pid_request calls.
    print "UDP PidStat in...\n" if $Debug;
    my ($pid,$exists,$onhost) = $Exister->recv_stat();
    return if !defined $pid;
    return if $exists;   # We only care about known-missing processes
    print "   UDP PidStat PID $pid no longer with us.  RIP.\n" if $Debug;
    # We don't maintain a table sorted by pid, as these messages
    # are rare, and there can be many locks per pid.
    foreach my $locki (values %Locks) {
	if ($locki->{locked} && $locki->{autounlock}
	    && $locki->{hostname} eq $onhost
	    && $locki->{pid} == $pid) {
	    print "\tUDP RIP Unlock\n" if $Debug;
	    locki_unlock($locki);		# break the lock
	}
    }
    print "   UDP RIP done\n\n" if $Debug;
}

######################################################################
######################################################################
#### Internals

sub locki_lock {
    # Give lock to next requestor that accepts it
    my $locki = shift || die;

    print "Locki_lock:1:Waiter count: ".$#{$locki->{waiters}}."\n" if $Debug;
    while (my $clientvar = shift @{$locki->{waiters}}) {
    	print "Locki_lock:2:Waiter count: ".$#{$locki->{waiters}}."\n" if $Debug;
	$locki->{locked} = 1;
	$locki->{owner} = $clientvar->{user};
	if ($clientvar->{timeout}) {
	    $locki->{timelimit} = $clientvar->{timeout} + fractime();
	} else {
	    $locki->{timelimit} = 0;
	}
	$locki->{autounlock} = $clientvar->{autounlock};
	$locki->{hostname} = $clientvar->{hostname};
	$locki->{pid} = $clientvar->{pid};
	$clientvar->{lock} = $locki->{lock};
	print "Issuing $locki->{lock} $locki->{owner}\n" if $Debug;
	# This is the only call to a client_ routine not in the direct
	# client call stack.  Thus we may need to process more commands
	# after this call
	if (client_status ($clientvar)) {
	    # Worked ok
	    client_service($clientvar, []);  # If any queued, handle more commands/ EOF
	    last; # Don't look for another lock waiter
	}
	# Else hung up, didn't get the lock, give to next guy
	print "Hangup  $locki->{lock} $locki->{owner}\n" if $Debug;
	locki_unlock ($locki);
    }
}

sub locki_unlock {
    # Unlock this lock
    my $locki = shift || die;
    $locki->{locked} = 0;
    $locki->{owner} = "unlocked";
    $locki->{autounlock} = 0;
    $locki->{hostname} = "";
    $locki->{pid} = 0;
    # Give it to someone else?
    while (!$locki->{locked} && defined $locki->{waiters}[0]) {
	# Note the new lock request client may not still be around, if so we
	# recurse back to this function with waiters one element shorter.
	locki_lock ($locki);
    }
    #TBD locki_maybe_delete ($locki);
}

sub locki_maybe_delete {
    my $locki = shift;
    if (!$locki->{locked} && !defined $locki->{waiters}[0]) {
	print "locki_delete: $locki->{lock}\n" if $Debug;
	delete $Locks{$locki->{lock}};
    }
}

sub recheck_locks {
    my $self = shift;
    # Main loop to see if any locks have changed state
    my $time = fractime();
    if (($self->{_recheck_locks_time}||0) < $time) {
	$self->{_recheck_locks_time} = $time + 1;
	foreach my $locki (values %Locks) {
	    _recheck_lock($locki,$time);
	}
    }
}

sub _recheck_lock {
    my $locki = shift;
    my $time = shift || fractime();
    # See if any locks have changed state
    if ($locki->{locked}) {
	if ($locki->{timelimit} && ($locki->{timelimit} <= $time)) {
	    print "Timeout $locki->{lock} $locki->{owner}\n" if $Debug;
	    locki_unlock ($locki);
	}
	elsif ($locki->{autounlock}) {   # locker said it was OK to break lock if he dies
	    if (($locki->{autounlock_check_time}||0) < $time) {
		$locki->{autounlock_check_time} = $time + 2;
		# Only check every 2 secs or so, else we can spend more time
		# doing the OS calls than it's worth
		my $dead = undef;
		if ($locki->{hostname} eq $Hostname) {	# lock owner is running on same host
		    $dead = IPC::PidStat::local_pid_doesnt_exist($locki->{pid});
		    if ($dead) {
			print "Autounlock $locki->{lock} $locki->{owner}\n" if $Debug;
			locki_unlock($locki);		# break the lock
		    }
		}
		if (!defined $dead) {
		    # Ask the other host if the PID is around
		    # Or, we had a permission problem so ask root.
		    print "UDP pid_request $locki->{hostname}\n" if $Debug;
		    $Exister->pid_request(host=>$locki->{hostname}, pid=>$locki->{pid});
		    # This may (or may not) return a UDP message with the status in it.
		    # If so, they will call exist_traffic.
		}
	    }
	}
    }
}

sub locki_lookup {
    my $lockname = shift || "lock";
    if (!defined $Locks{$lockname}{lock}) {
	$Locks{$lockname} = {
	    lock=>$lockname,
	    locked=>0,
	    owner=>"unlocked",
	    waiters=>[],
	};
    }
    return $Locks{$lockname};
}

sub DESTROY {
    my $self = shift;
    print "DESTROY\n" if $Debug;
    if (($self->{family} eq 'UNIX') && $self->{unix_socket_created}){
    	unlink $self->{port};
    }
}

######################################################################
#### Package return
1;
