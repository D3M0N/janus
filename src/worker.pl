#!/usr/bin/perl
# Copyright (C) 2007-2008 Daniel De Graaf
# Released under the GNU Affero General Public License v3
use strict;
use warnings;
BEGIN {
	# Support for taint mode: we don't acually need most of these protections
	# as the person running janus.pl is assumed to have shell access anyway.
	# The real benefit of taint mode is protecting IRC-sourced data
	$_ = $ENV{PATH};
	s/:.(:|$)/$1/;
	s/~/$ENV{HOME}/g;
	/(.*)/;
	$ENV{PATH} = $1;
	$ENV{SHELL} = '/bin/sh';
	delete @ENV{'IFS', 'CDPATH', 'ENV', 'BASH_ENV'};
	do './src/Janus.pm' or die $@;
}
use POSIX 'setsid';

our $VERSION = '1.14';

# control socket on stdin, needs to be read/write
open $RemoteControl::sock, '+>&=0';
select $RemoteControl::sock; $| = 1;
select STDOUT; $| = 1;

$SIG{PIPE} = 'IGNORE';
$SIG{CHLD} = 'IGNORE';

if ($^P) {
	# $^P is nonzero if run inside perl -d
	require Log::Debug;
	no warnings 'once';
	@Log::listeners = $Log::Debug::INST;
	&Log::dump_queue();
}

my $line = <$RemoteControl::sock>;
chomp $line;
if ($line eq 'BOOT') {
	&Janus::load('Conffile') or die;
	&Janus::insert_full(+{ type => 'INITCONF', (@ARGV ? (file => $ARGV[0]) : ()) });
	&Log::timestamp($Janus::time);
	print $RemoteControl::sock $Conffile::netconf{set}{ipv6} ? "1\n" : "0\n";
	&Janus::load('RemoteControl') or die;
	&Janus::insert_full(+{ type => 'INIT', args => \@ARGV });
	&Janus::insert_full(+{ type => 'RUN' });
} elsif ($line =~ /^RESTORE (\S+)/) {
	die 'TODO';
} else {
	die "Bad line from control socket: $line";
}
eval {
	&RemoteControl::timestep while 1;
	1;
} ? &Log::info("Goodbye!\n") : &Log::err("Aborting, error=$@");
