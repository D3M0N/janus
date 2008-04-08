# Copyright (C) 2007-2008 Daniel De Graaf
# Released under the GNU Affero General Public License v3
package Commands::Debug;
use strict;
use warnings;
use Data::Dumper;
use Modes;

eval {
	&Data::Dumper::init_refaddr_format();
	# BUG in Data::Dumper, running this is needed before using Seen
};

our $DUMP_SEQ;

sub dump_all_globals {
	my %rv;
	for my $pkg (@_) {
		my $ns = do { no strict 'refs'; \%{$pkg.'::'} };
		next unless $ns;
		for my $var (keys %$ns) {
			next if $var =~ /:/ || $var eq 'ISA'; # perl internal variable
			my $scv = *{$ns->{$var}}{SCALAR};
			my $arv = *{$ns->{$var}}{ARRAY};
			my $hsv = *{$ns->{$var}}{HASH};
			my $cdv = *{$ns->{$var}}{CODE};
			$rv{'$'.$pkg.'::'.$var} = $$scv if $scv && defined $$scv;
			$rv{'@'.$pkg.'::'.$var} = $arv  if $arv && scalar @$arv;
			$rv{'%'.$pkg.'::'.$var} = $hsv  if $hsv && scalar keys %$hsv;
			$rv{'&'.$pkg.'::'.$var} = $cdv  if $cdv;
		}
	}
	\%rv;
}

sub dump_now {
	my $fn = 'log/dump-'.$Janus::time.'-'.++$DUMP_SEQ;
	while (-f $fn) {
		$fn = 'log/dump-'.$Janus::time.'-'.++$DUMP_SEQ;
	}
	open my $dump, '>', $fn or return undef;
	my $gbls = dump_all_globals(keys %Janus::modules);
	my $objs = &Persist::dump_all_refs();
	my %seen;
	my @tmp = keys %$gbls;
	for my $var (@tmp) {
		next unless $var =~ s/^&//;
		$seen{'*'.$var} = delete $gbls->{'&'.$var};
	}
	for my $pkg (keys %Persist::vars) {
		for my $var (keys %{$Persist::vars{$pkg}}) {
			$seen{"\$Replay::thaw_var->('$pkg','$var')"} = $Persist::vars{$pkg}{$var};
		}
	}
	for my $q (@Connection::queues) {
		my $sock = $q->[&Connection::SOCK()];
		next unless ref $sock;
		$seen{'$Replay::thaw_fd->('.$q->[&Connection::FD()].')'} = $sock;
	}

	my $dd = Data::Dumper->new([]);
	$dd->Sortkeys(1);
	$dd->Bless('findobj');
	$dd->Seen(\%seen);

	$dd->Names([qw(gnicks gchans gnets ijnets)])->Values([
		\%Janus::gnicks,
		\%Janus::gchans,
		\%Janus::gnets,
		\%Janus::ijnets,
	]);
	$dd->Purity(1);
	print $dump $dd->Dump();
	$dd->Purity(0);
	$dd->Names(['global'])->Values([$gbls]);
	print $dump $dd->Dump();
	$dd->Names(['object'])->Values([$objs]);
	print $dump $dd->Dump();
	$dd->Names(['arg'])->Values([\@_]);
	print $dump $dd->Dump();
	close $dump;
	$fn;
}

&Janus::command_add({
	cmd => 'dump',
	help => 'Dumps current janus internal state to a file',
	acl => 1,
	code => sub {
		my $fn = dump_now(@_);
		&Janus::jmsg($_[0], 'State dumped to file '.$fn);
	},
}, {
	cmd => 'testdie',
	acl => 1,
	code => sub {
		die "You asked for it!";
	},
});

&Janus::hook_add(
	ALL => 'die' => sub {
		eval {
			dump_now(@_);
			1;
		} or print "Error in dump: $@\n";
	},
);

1;
