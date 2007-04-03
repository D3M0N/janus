package Interface;
use base 'Network';
use Nick;
use strict;
use warnings;

my %cmds = (
	unk => sub {
		my($j, $nick) = @_;
		$j->jmsg($nick, 'Unknown command. Use "help" to see available commands');
	}, help => sub {
		my($j, $nick) = @_;
		$j->jmsg($nick, 'Janus2 Help',
			' link $localchan $network $remotechan - links a channel with a remote network',
			' delink $chan - delinks a channel from all other networks',
			'These commands are restricted to IRC operators:',
			' ban list - list all active janus bans',
			' ban add $expr $reason $expire - add a ban',
			' ban del $expr - remove a ban',
			'  Bans are perl regular expressions matched against nick!ident@host%network on any',
			'  remote joins to a shared channel',
			' list - shows a list of the linked networks; will eventually show channels too',
			' rehash - reload the config and attempt to reconnect to split servers',
			' die - quit immediately',
		);
	}, ban => sub {
		my($j, $nick) = @_;
		my($cmd, @arg) = split /\s+/;
		return $j->jmsg("You must be an IRC operator to use this command") unless $nick->{mode}->{oper};
		my $net = $nick->{homenet};
		if ($cmd =~ /^l/i) {
			for my $expr (sort keys %{$net->{ban}}) {
				my $ban = $net->{ban}->{$expr};
				my $expire = $ban->{expire} ? 'expires on '.gmtime($ban->{expire}) : 'does not expire';
				$j->jmsg($nick, "$expr - set by $ban->{setter}, $expire - $ban->{reason}");
			}
		} elsif ($cmd =~ /^a/i) {
			unless ($arg[1]) {
				$j->jmsg($nick, 'Use: ban add $expr $reason $duration');
				return;
			}
			my %b = (
				expr => $arg[0],
				reason => $arg[1],
				expire => $arg[2] ? $arg[2] + time : 0,
				setter => $nick->{homenick},
			);
			$net->{ban}->{$arg[0]} = \%b;
			$j->jmsg($nick, 'Ban added');
		} elsif ($cmd =~ /^d/i) {
			if (delete $net->{ban}->{$arg[0]}) {
				$j->jmsg($nick, 'Ban removed');
			} else {
				$j->jmsg($nick, 'Could not find ban - use ban list to see a list of all bans');
			}
		}
	}, list => sub {
		my($j, $nick) = @_;
		return $j->jmsg("You must be an IRC operator to use this command") unless $nick->{mode}->{oper};
		$j->jmsg($nick, 'Linked networks: '.join ' ', sort keys %{$j->{nets}});
		# TODO display available channels when that is set up
	}, 'link' => sub {
		# TODO evaluate for jlink nets
		my($j, $nick) = @_;
		my($cname1, $nname2, $cname2) = /(#\S+)\s+(\S+)\s*(#\S+)/ or do {
			$j->jmsg($nick, 'Usage: link $localchan $network $remotechan');
			return;
		};
		my $net1 = $nick->{homenet};
		my $net2 = $j->{nets}->{lc $nname2} or do {
			$j->jmsg($nick, "Cannot find network $nname2");
			return;
		};
		my $chan1 = $net1->{chans}->{lc $cname1} or do {
			$j->jmsg($nick, "Cannot find channel $cname1");
			return;
		};
		my $chan2 = $net2->{chans}->{lc $cname2} or do {
			$j->jmsg($nick, "Cannot find channel $cname2");
			return;
		};
		
		unless ($nick->{mode}->{oper}) {
			unless ($chan1->{nmode}->{$nick->id()}->{n_owner}) {
				$j->jmsg("You must be a channel owner to use this command");
				return;
			}
		}
		# TODO switch between LINKREQ and LINK
		$j->append(+{
			type => 'LINK',
			src => $nick,
			chan1 => $chan1,
			chan2 => $chan2,
		});
	}, 'delink' => sub {
		my($j, $nick, $cname) = @_;
		my $snet = $nick->{homenet};
		my $chan = $snet->chan($cname) or do {
			$j->jmsg($nick, "Cannot find channel $cname");
			return;
		};
		unless ($nick->{mode}->{oper}) {
			unless ($chan->{nmode}->{$nick->id()}->{n_owner}) {
				$j->jmsg("You must be a channel owner to use this command");
				return;
			}
		}
			
		$j->append(+{
			type => 'DELINK',
			src => $nick,
			dst => $chan,
			net => $snet,
		});
	}, rehash => sub {
		my($j, $nick) = @_;
		return $j->jmsg("You must be an IRC operator to use this command") unless $nick->{mode}->{oper};
		$j->append(+{
			type => 'REHASH',
			sendto => [],
		});
	}, 'die' => sub {
		my($j, $nick) = @_;
		return $j->jmsg("You must be an IRC operator to use this command") unless $nick->{mode}->{oper};
		exit 0;
	},
);

sub modload {
	my $class = shift;
	my $janus = shift;
	my $inick = shift || 'janus';

	my %neth = (
		id => 'janus',
		netname => 'Janus',
	);
	my $int = \%neth;
	bless $int, $class;

	$janus->link($int);

	my $nick = Nick->new(
		homenet => $int,
		homenick => $inick,
		nickts => 100000000,
		ident => 'janus',
		host => 'services.janus',
		name => 'Janus Control Interface',
		mode => { oper => 1, service => 1 },
		_is_janus => 1,
	);
	$int->{nicks}->{lc $inick} = $nick;
	$janus->{janus} = $nick;
	
	$janus->hook_add($class, 
		NETLINK => act => sub {
			my($j,$act) = @_;
			$j->append(+{
				type => 'CONNECT',
				dst => $j->{janus},
				net => $act->{net},
			});
		}, NETSPLIT => act => sub {
			my($j,$act) = @_;
			my $net = $act->{net};
			delete $j->{janus}->{nets}->{$net->id()};
			my $jnick = delete $j->{janus}->{nicks}->{$net->id()};
			$net->release_nick($jnick);
		}, MSG => parse => sub {
			my($j,$act) = @_;
			my $nick = $act->{src};
			my $dst = $act->{dst};
			if ($dst->{_is_janus}) {
				return 1 unless $nick;
				local $_ = $act->{msg};
				s/^\s*(\S+)\s*// or return;
				my $cmd = exists $cmds{lc $1} ? lc $1 : 'unk';
				$cmds{$cmd}->($j, $nick, $_);
				return 1;
			} elsif ($dst->isa('Nick') && !$nick->is_on($dst->{homenet})) {
				$j->append(+{
					type => 'MSG',
					notice => 1,
					src => $j->{janus},
					dst => $nick,
					msg => 'You must join a shared channel to speak with remote users',
				}) unless $act->{notice};
				return 1;
			}
			undef;
		},
	);
}

sub parse { () }
sub vhost { 'services' }
sub send { }
