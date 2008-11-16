# Copyright (C) 2007-2008 Daniel De Graaf
# Released under the GNU Affero General Public License v3
package Server::InterJanus;
use strict;
use warnings;
use Persist 'RemoteJanus';
use Scalar::Util qw(isweak weaken);
use Nick;
use Channel;
use RemoteNetwork;

our $IJ_PROTO = 1.9;

our(@sendq, @auth);
&Persist::register_vars(qw(sendq auth));

sub str {
	warn;
	"";
}

sub is_linked {
	$auth[${$_[0]}] == 2;
}

my %esc2char = (
	e => '\\',
	g => '>',
	l => '<',
	z => '=',
	n => "\n",
	q => '"',
);

my %v_type; %v_type = (
	' ' => sub {
		undef;
	}, '>' => sub {
		undef;
	}, '"' => sub {
		s/^"([^"]*)"//;
		my $v = $1;
		$v =~ s/\\(.)/$esc2char{$1}/g;
		$v;
	}, 'n' => sub {
		s/^n:([^ >]+)(:[^: >]+)// or return undef;
		$Janus::gnicks{$1.$2} || $Janus::gnets{$1};
	}, 'c' => sub {
		s/^c:([^ >]+)// or return undef;
		$Janus::gchans{$1};
	}, 's' => sub {
		s/^s:([^ >]+)// or return undef;
		$Janus::gnets{$1};
	}, 'j' => sub {
		s/^j:([^ >]+)// or return undef;
		return $Janus::global if $1 eq '*';
		return $RemoteJanus::self if $1 eq $RemoteJanus::self->id;
		$Janus::ijnets{$1};
	}, '<a' => sub {
		my @arr;
		s/^<a// or warn;
		while (s/^ //) {
			my $v_t = substr $_,0,1;
			$v_t = substr $_,0,2 if $v_t eq '<';
			push @arr, $v_type{$v_t}->(@_);
		}
		s/^>// or warn;
		\@arr;
	}, '<h' => sub {
		my $ij = shift;
		my $h = {};
		s/^<h// or warn;
		$ij->kv_pairs($h);
		s/^>// or warn;
		$h;
	}, '<s' => sub {
		my $ij = shift;
		my $h = {};
		s/^<s// or warn;
		$ij->kv_pairs($h);
		s/^>// or warn;
		if ($Janus::gnets{$h->{gid}} || $Janus::nets{$h->{id}}) {
			# this is a NETLINK of a network we already know about.
			# We either have a loop or a name collision. Either way, the IJ link
			# cannot continue
			&Event::insert_full(+{
				type => 'JNETSPLIT',
				net => $ij,
				msg => "InterJanus network name collision: network $h->{id} already exists"
			});
			return undef;
		}
		unless ($ij->jparent($h->{jlink})) {
			&Event::insert_full(+{
				type => 'JNETSPLIT',
				net => $ij,
				msg => "Network misintroduction: $h->{jlink} invalid"
			});
			return undef;
		}
		RemoteNetwork->new(%$h);
	}, '<j' => sub {
		my $ij = shift;
		my $h = {};
		s/^<j// or warn;
		$ij->kv_pairs($h);
		s/^>// or warn;
		my $id = $h->{id};
		my $parent = $h->{parent};
		if ($Janus::ijnets{$id} || $id eq $RemoteJanus::self->id) {
			&Event::insert_full(+{
				type => 'JNETSPLIT',
				net => $ij,
				msg => "InterJanus network name collision: IJ network $h->{id} already exists"
			});
			return undef;
		}
		unless ($ij->jparent($parent)) {
			&Event::insert_full(+{
				type => 'JNETSPLIT',
				net => $ij,
				msg => "IJ Network misintroduction: $h->{jlink} invalid"
			});
			return undef;
		}
		RemoteJanus->new(parent => $parent, id => $id);
	}, '<c' => sub {
		my $ij = shift;
		my $h = {};
		s/^<c// or warn;
		$ij->kv_pairs($h);
		s/^>// or warn;
		# this creates a new object every time because LINK will fail if we
		# give it a cached item, and LOCKACK needs to create a lot of the time
		Channel->new(%$h);
	}, '<n' => sub {
		my $ij = shift;
		my $h = {};
		s/^<n// or warn;
		$ij->kv_pairs($h);
		s/^>// or warn;
		return undef unless $h->{gid} && ref $h->{net} && $ij->jparent($h->{net});
		my $n = $Janus::gnicks{$h->{gid}};
		unless ($n) {
			$Janus::gnicks{$h->{gid}} = $n = Nick->new(%$h);
		}
		$n;
	},
);

sub kv_pairs {
	my($ij, $h) = @_;
	while (s/^\s+(\S+)=//) {
		my $k = $1;
		my $v_t = substr $_,0,1;
		$v_t = substr $_,0,2 if $v_t eq '<';
		return warn "Cannot find v_t for: $_" unless $v_type{$v_t};
		return warn "Duplicate key $k" if $h->{$k};
		$h->{$k} = $v_type{$v_t}->($ij);
	}
}

sub intro {
	my($ij,$nconf, $peer) = @_;
	$sendq[$$ij] = '';
	$auth[$$ij] = $peer ? 0 : 1;
	$ij->send(+{
		type => 'InterJanus',
		version => $IJ_PROTO,
		id => $RemoteJanus::self->id(),
		rid => $nconf->{id},
		pass => $nconf->{sendpass},
		ts => $Janus::time,
	}) if $auth[$$ij];
}

sub jlink {
	$_[0];
}

sub send {
	my $ij = shift;
	my @out = &EventDump::dump_act(@_);
	for (@out) {
		&Log::netout($ij, $_) unless /^<MSG /;
	}
	$sendq[$$ij] .= join '', map "$_\n", @out;
}

sub delink {
	my($net,$msg) = @_;
	delete $Janus::pending{$net->id};
	&Event::insert_full(+{
		type => 'JNETSPLIT',
		net => $net,
		msg => $msg,
	});
}

sub dump_sendq {
	my $ij = shift;
	my $q = $sendq[$$ij];
	$sendq[$$ij] = '';
	$q;
}

sub parse {
	&Log::netin(@_) unless /^<MSG /;
	my $ij = shift;
	local $_ = $_[0];

	s/^\s*<([^ >]+)// or do {
		&Log::err_in($ij, "Invalid IJ line\n");
		return ();
	};
	my $act = { type => $1, IJ_RAW => $_[0] };
	$ij->kv_pairs($act);
	&Log::err_in($ij, "bad line: $_[0]") unless /^\s*>\s*$/;
	$act->{except} = $ij;
	if ($act->{type} eq 'PING') {
		$ij->send({ type => 'PONG', pingts => $act->{ts}, ts => $Janus::time });
	} elsif ($auth[$$ij] == 2) {
		return $act;
	} elsif ($act->{type} eq 'InterJanus') {
		my $id = $RemoteJanus::id[$$ij];
		if ($id && $act->{id} ne $id) {
			&Log::err_in($ij, "Unexpected ID reply $act->{id} from IJ $id");
		} else {
			$id = $RemoteJanus::id[$$ij] = $act->{id};
		}
		my $ts_delta = abs($Janus::time - $act->{ts});
		my $nconf = $Conffile::netconf{$id};
		if ($act->{version} ne $IJ_PROTO) {
			&Log::err_in($ij, "Unsupported InterJanus version $act->{version} (local $IJ_PROTO)");
		} elsif ($RemoteJanus::self->id() ne $act->{rid}) {
			&Log::err_in($ij, "Unexpected connection: remote was trying to connect to $act->{rid}");
		} elsif (!$nconf) {
			&Log::err_in($ij, "Unknown InterJanus server $id");
		} elsif ($act->{pass} ne $nconf->{recvpass}) {
			&Log::err_in($ij, "Failed authorization");
		} elsif ($Janus::ijnets{$id} && $Janus::ijnets{$id} ne $ij) {
			&Log::err_in($ij, "Already connected");
		} elsif ($ts_delta >= 20) {
			&Log::err_in($ij, "Clocks are too far off (delta=$ts_delta here=$Janus::time there=$act->{ts})");
		} else {
			$act->{net} = $ij;
			$act->{type} = 'JNETLINK';
			delete $act->{$_} for qw/pass version ts id rid IJ_RAW/;
			unless ($auth[$$ij]) {
				$ij->send(+{
					type => 'InterJanus',
					version => $IJ_PROTO,
					id => $RemoteJanus::self->id(),
					rid => $nconf->{id},
					pass => $nconf->{sendpass},
					ts => $Janus::time,
				});
			}
			$auth[$$ij] = 2;
			return $act;
		}
		if ($Janus::ijnets{$id} && $Janus::ijnets{$id} eq $ij) {
			delete $Janus::ijnets{$id};
		}
	}
	return ();
}

&Event::hook_add(
	JNETLINK => act => sub {
		my $act = shift;
		my $ij = $act->{net};
		return unless $ij->isa(__PACKAGE__);
		for my $net (values %Janus::ijnets) {
			next if $net eq $ij || $net eq $RemoteJanus::self;
			$ij->send(+{
				type => 'JNETLINK',
				net => $net,
			});
		}
		for my $net (values %Janus::nets) {
			$ij->send(+{
				type => 'NETLINK',
				net => $net,
			});
			$ij->send(+{
				type => 'LINKED',
				net => $net,
			}) if $net->is_synced();
		}
		$ij->send(+{
			type => 'JLINKED',
		});
	}
);

1;
