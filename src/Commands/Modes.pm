# Copyright (C) 2007-2008 Daniel De Graaf
# Released under the GNU Affero General Public License v3
package Commands::Modes;
use strict;
use warnings;
use Data::Dumper;
use Modes;

&Janus::command_add({
	cmd => 'showmode',
	help => 'Shows the current intended modes of a channel',
	details => [
		"\002SHOWMODE\002 #channel - shows the intended modes of the channel on your network",
	],
	code => sub {
		my($src,$dst,$cname) = @_;
		my $hn = $src->homenet;
		my $chan = $hn->chan($cname,0) || $Janus::gchans{$cname};
		return &Janus::jmsg($dst, 'That channel does not exist') unless $chan;
		unless ($chan->has_nmode(owner => $src) || $src->has_mode('oper')) {
			&Janus::jmsg($dst, "You must be a channel owner or oper to use this command");
			return;
		}
		if ($hn->isa('LocalNetwork')) {
			my @modes = &Modes::to_multi($hn, &Modes::delta(undef, $chan), 0, 400);
			&Janus::jmsg($dst, join ' ', $cname, @$_) for @modes;
		}
		
		my $modeh = $chan->all_modes();
		unless ($modeh && scalar %$modeh) {
			&Janus::jmsg($dst, "No modes set on $cname");
			return;
		}
		my $out = '';
		for my $mk (sort keys %$modeh) {
			my $t = $Modes::mtype{$mk} || '?';
			my $mv = $modeh->{$mk};
			if ($t eq 'r') {
				$out .= ' '.$mk.('+'x($mv - 1));
			} elsif ($t eq 'v') {
				$out .= ' '.$mk.'='.$mv;
			} elsif ($t eq 'l') {
				$out .= join ' ', '', $mk.'={', @$mv, '}';
			} else {
				&Log::err("bad mode $mk:$mv - $t?\n");
			}
		}
		&Janus::jmsg($dst, $cname.$1) while $out =~ s/(.{300,450}) / /;
		&Janus::jmsg($dst, $cname.$out);
	},
}, {
	cmd => 'showtopic',
	help => 'Shows the current intended topic of a channel',
	details => [
		"\002SHOWTOPIC\002 #channel - shows the intended topic of the channel on your network",
	],
	code => sub {
		my($src,$dst,$cname) = @_;
		my $hn = $src->homenet;
		my $chan = $hn->chan($cname,0) || $Janus::gchans{$cname};
		return &Janus::jmsg($dst, 'That channel does not exist') unless $chan;
		my $top = $chan->topic();
		&Janus::jmsg($dst, $cname . ' ' . $top);
	},
}, {
	cmd => 'setmode',
	help => 'Sets a mode by its long name',
	details => [
		"\002SETMODE\002 #channel +mode1 -mode2 +mode3=value",
		"For a list of modes, see the \002LISTMODES\002 command.",
		"For tristate modes, use multiple + signs to set a higher level",
	],
	code => sub {
		my($src,$dst,$cname,@argin) = @_;
		my $hn = $src->homenet;
		my $chan = $hn->chan($cname,0) || $Janus::gchans{$cname};
		return &Janus::jmsg($dst, 'That channel does not exist') unless $chan;
		unless ($chan->has_nmode(owner => $src) || $src->has_mode('oper')) {
			&Janus::jmsg($dst, "You must be a channel owner or oper to use this command");
			return;
		}
		my(@modes,@args,@dirs);
		for (@argin) {
			/^([-+]+)([^=]+)(?:=(.+))?$/ or do {
				&Janus::jmsg($dst, "Invalid mode $_");
				return;
			};
			my($d,$txt,$v) = ($1,$2,$3);
			my $type = $Modes::mtype{$txt} or do {
				&Janus::jmsg($dst, "Unknown mode $txt");
				return;
			};
			if ($type eq 'r') {
				if ($d =~ /-+/) {
					$v = $chan->get_mode($txt);
					$d = '-';
				} else {
					$v = length $d;
					$d = '+';
				}
			} elsif ($type eq 'n') {
				$v = $hn->nick($v) or do {
					&Janus::jmsg($dst, "Cannot find nick");
					return;
				};
			}
			if ($type eq 'v' && $d eq '-') {
				$v = $chan->get_mode($txt);
			}
			if (length $d > 1 || !defined $v) {
				&Janus::jmsg($dst, "Invalid mode $_");
				return;
			}
			unshift @dirs, $d;
			unshift @modes, $txt;
			unshift @args, $v;
		}
		if (@dirs) {
			&Janus::append(+{
				type => 'MODE',
				src => $Interface::janus,
				dst => $chan,
				mode => \@modes,
				args => \@args,
				dirs => \@dirs,
			});
			&Janus::jmsg($dst, 'Done');
		} else {
			&Janus::jmsg($dst, 'Nothing to do');
		}
	},
}, {
	cmd => 'listmodes',
	help => 'Shows a list of the long modes\' names',
	code => sub {
		my($src,$dst,$w) = @_;
		my $net = $src->homenet;
		$w ||= 5;
		my @nmodes = sort keys %Nick::umodebit;
		my @cmodes = sort keys %Modes::mtype;
		my $l = 0;
		$l < length $_ and $l = length $_ for @cmodes, @nmodes;
		my $nc = 1 + $#nmodes / $w;
		my $cc = 1 + $#cmodes / $w;
		my $ex = ' %-'.$l.'s %2s ';
		&Janus::jmsg($dst, 'Nick modes:');
		for my $i (0..($nc-1)) {
			my $line = '';
			for my $m (map $nmodes[$nc*$_ + $i], 0 .. ($w-1)) {
				my $netv = $net->can('txt2umode') ? $net->txt2umode($m) : '';
				$netv = '' if ref $netv;
				$line .= sprintf $ex, $m, $netv, '';
			}
			&Janus::jmsg($dst, $line);
		}
		&Janus::jmsg($dst, 'Channel modes:');
		for my $i (0..($cc-1)) {
			my $line = '';
			for my $m (map $cmodes[$cc*$_ + $i], 0 .. ($w-1)) {
				my $type = $Modes::mtype{$m};
				my $netv = '';
				if ($net->can('txt2cmode')) {
					$netv .= $net->txt2cmode($_ . '_' . $m) for qw/r t1 t2 v s n l/;
				}
				$line .= sprintf $ex, $m, $netv, $type;
			}
			&Janus::jmsg($dst, $line);
		}
	},
});

1;
