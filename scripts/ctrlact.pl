# ctrlact.pl — Irssi script for fine-grained control of activity indication
#
# © 2017 martin f. krafft <madduck@madduck.net>
# Released under the MIT licence.
#
### Usage:
#
# /script load ctrlact
#
# If you like a busy activity statusbar, this script is not for you.
#
# If, on the other hand, you don't care about most activity, but you do want
# the ability to define per-item and per-window, what level of activity should
# trigger a change in the statusbar, then ctrlact might be for you.
#
# For instance, you might never want to be disturbed by activity in any
# channel, unless someone highlights you. However, you do want all activity
# in queries, as well as an indication about any chatter in your company
# channels. The following ctrlact map would do this for you:
#
#	channel		/^#myco-/	messages
#	channel		*		hilights
#	query		*		all
#
# These three lines would be interpreted/read as:
#  "only messages or higher in a channel matching /^#myco-/ should trigger act"
#  "in all other channels, only hilights (or higher) should trigger act"
#  "messages of all levels should trigger act in queries"
#
# The activity level in the third column is thus to be interpreted as
#  "the minimum level of activity that will trigger an indication"
#
# Loading this script per-se should not change anything, except it will create
# ~/.irssi/ctrlact with some informational content, including the defaults and
# some examples.
#
# The four activity levels are, and you can use either the words, or the
# integers in the map.
#
#	all		(data_level: 1)
#	messages	(data_level: 2)
#	hilights	(data_level: 3)
#	none		(data_level: 4)
#
# Note that the name is either matched in full and verbatim, or treated like
# a regular expression, if it starts and ends with the same punctuation
# character. The asterisk ('*') is special and simply gets translated to /.*/
# internally. No other wildcards are supported.
#
# Once you defined your mappings, please don't forget to /ctrlact reload them.
# You can then use the following commands from Irssi to check out the result:
#
#	# list all mappings
#	/ctrlact list
#
#	# query the applicable activity levels, possibly limited to
#	# windows/channels/queries
#	/ctrlact query name [name, …] [-window|-channel|-query]
#
#	# display the applicable level for each window/channel/query
#	/ctrlact show [-window|-channel|-query]
#
# There's an interplay between window items and windows here, and you can
# specify mininum activity levels for each. Here are the rules:
#
# 1. if the minimum activity level of a window item (channel or query) is not
#    reached, then the window is prevented from indicating activity.
# 2. if traffic in a window item does reach minimum activity level, then the
#    minimum activity level of the window is considered, and activity is only
#    indicated if the window's minimum activity level is lower.
#
# In general, this means you'd have windows defaulting to 'all', but it might
# come in handy to move window items to windows with min.levels of 'hilights'
# or even 'none' in certain cases, to further limit activity indication for
# them.
#
# You can use the Irssi settings activity_msg_level and activity_hilight_level
# to specify which IRC levels will be considered messages and hilights. Note
# that if an activity indication is inhibited, then there also won't be
# a beep (cf. beep_msg_level).
#
### Settings:
#
# /set ctrlact_map_file [~/.irssi/ctrlact]
#   Controls where the activity control map will be read from (and saved to)
#
# /set ctrlact_fallback_(channel|query|window)_threshold [1]
#   Controls the lowest data level that will trigger activity for channels,
#   queries, and windows respectively, if no applicable mapping could be
#   found.
#
# /set ctrlact_debug [off]
#   Turns on debug output. Not that this may itself be buggy, so please don't
#   use it unless you really need it.
#
### To-do:
#
# - figure out interplay with activity_hide_level
# - /ctrlact add/delete/move and /ctrlact save, maybe
# - ability to add a server tag to an item name to make matches more specific
# - make beep inhibition configurable
# - completion for commands
#
use strict;
use warnings;
use Irssi;
use Text::ParseWords;

our $VERSION = '1.0';

our %IRSSI = (
    authors     => 'martin f. krafft',
    contact     => 'madduck@madduck.net',
    name        => 'ctrlact',
    description => 'allows per-channel control over activity indication',
    license     => 'MIT',
    changed     => '2017-02-12'
);

### DEFAULTS AND SETTINGS ######################################################

my $debug = 0;
my $map_file = Irssi::get_irssi_dir()."/ctrlact";
my $fallback_channel_threshold = 1;
my $fallback_query_threshold = 1;
my $fallback_window_threshold = 1;

Irssi::settings_add_str('ctrlact', 'ctrlact_map_file', $map_file);
Irssi::settings_add_bool('ctrlact', 'ctrlact_debug', $debug);
Irssi::settings_add_int('ctrlact', 'ctrlact_fallback_channel_threshold', $fallback_channel_threshold);
Irssi::settings_add_int('ctrlact', 'ctrlact_fallback_query_threshold', $fallback_query_threshold);
Irssi::settings_add_int('ctrlact', 'ctrlact_fallback_window_threshold', $fallback_window_threshold);

sub sig_setup_changed {
	$debug = Irssi::settings_get_bool('ctrlact_debug');
	$map_file = Irssi::settings_get_str('ctrlact_map_file');
	$fallback_channel_threshold = Irssi::settings_get_int('ctrlact_fallback_channel_threshold');
	$fallback_query_threshold = Irssi::settings_get_int('ctrlact_fallback_query_threshold');
	$fallback_window_threshold = Irssi::settings_get_int('ctrlact_fallback_window_threshold');
}
Irssi::signal_add('setup changed', \&sig_setup_changed);
sig_setup_changed();

my $changed_since_last_save = 0;

my @DATALEVEL_KEYWORDS = ('all', 'messages', 'hilights', 'none');

### HELPERS ####################################################################

my $_inhibit_debug_activity = 0;
sub debugprint {
	return unless $debug;
	my ($msg, @rest) = @_;
	$_inhibit_debug_activity = 1;
	Irssi::print("ctrlact debug: ".$msg);
	$_inhibit_debug_activity = 0;
}

sub error {
	my ($msg) = @_;
	Irssi::print("ctrlact: ERROR: $msg", MSGLEVEL_CLIENTERROR);
}

my @window_thresholds;
my @channel_thresholds;
my @query_thresholds;

sub match {
	my ($pat, $text) = @_;
	my $npat = ($pat eq '*') ? '/.*/' : $pat;
	if ($npat =~ m/^(\W)(.+)\1$/) {
		my $re = qr/$2/;
		$pat = $2 unless $pat eq '*';
		return $pat if $text =~ /$re/i;
	}
	else {
		return $pat if lc($text) eq lc($npat);
	}
	return 0;
}

sub to_data_level {
	my ($kw) = @_;
	return $1 if $kw =~ m/^(\d+)$/;
	foreach my $i (2..4) {
		my $matcher = qr/^$DATALEVEL_KEYWORDS[5-$i]$/;
		return 6-$i if $kw =~ m/$matcher/i;
	}
	return 1;
}

sub from_data_level {
	my ($dl) = @_;
	die "Invalid numeric data level: $dl" unless $dl =~ m/^([1-4])$/;
	return $DATALEVEL_KEYWORDS[$dl-1];
}

sub walk_match_array {
	my ($name, $type, @arr) = @_;
	foreach my $pair (@arr) {
		my $match = match($pair->[0], $name);
		next unless $match;
		my $result = to_data_level($pair->[1]);
		my $tresult = from_data_level($result);
		$name = '(unnamed)' unless length $name;
		debugprint("$name ($type) matches '$match' → '$tresult' ($result)");
		return $result
	}
	return -1;
}

sub get_mappings_table {
	my (@arr) = @_;
	my @ret = ();
	for (my $i = 0; $i < @arr; $i++) {
		push @ret, sprintf("%4d: %-40s %-10s", $i, $arr[$i]->[0], $arr[$i]->[1]);
	}
	return join("\n", @ret);
}

sub get_specific_threshold {
	my ($type, $name) = @_;
	$type = lc($type);
	if ($type eq 'window') {
		return walk_match_array($name, $type, @window_thresholds);
	}
	elsif ($type eq 'channel') {
		return walk_match_array($name, $type, @channel_thresholds);
	}
	elsif ($type eq 'query') {
		return walk_match_array($name, $type, @query_thresholds);
	}
	else {
		die "ctrlact: can't look up threshold for type: $type";
	}
}

sub get_item_threshold {
	my ($chattype, $type, $name) = @_;
	my $ret = get_specific_threshold($type, $name);
	return $ret if $ret > 0;
	return ($type eq 'CHANNEL') ? $fallback_channel_threshold : $fallback_query_threshold;
}

sub get_win_threshold {
	my ($name) = @_;
	my $ret = get_specific_threshold('window', $name);
	return ($ret > 0) ? $ret : $fallback_window_threshold;
}

sub print_levels_for_all {
	my ($type, @arr) = @_;
	Irssi::print("ctrlact: $type mappings:");
	for (my $i = 0; $i < @arr; $i++) {
		my $name = $arr[$i]->{'name'};
		my $t = get_specific_threshold($type, $name);
		my $c = ($type eq 'window') ? $arr[$i]->{'refnum'} : $i;
		printf CLIENTCRAP "%4d: %-40s → %d (%s)", $c, $name, $t, from_data_level($t);
	}
}

### HILIGHT SIGNAL HANDLERS ####################################################

my $_inhibit_bell = 0;
my $_inhibit_window = 0;

sub maybe_inhibit_witem_hilight {
	my ($witem, $oldlevel) = @_;
	return unless $witem;
	$oldlevel = 0 unless $oldlevel;
	my $newlevel = $witem->{'data_level'};
	return if ($newlevel <= $oldlevel);

	$_inhibit_window = 0;
	$_inhibit_bell = 0;
	my $wichattype = $witem->{'chat_type'};
	my $witype = $witem->{'type'};
	my $winame = $witem->{'name'};
	my $threshold = get_item_threshold($wichattype, $witype, $winame);
	my $inhibit = $newlevel > 0 && $newlevel < $threshold;
	debugprint("$winame: witem $wichattype:$witype:\"$winame\" $oldlevel → $newlevel (".($inhibit ? "< $threshold, inhibit" : ">= $threshold, pass").')');
	if ($inhibit) {
		Irssi::signal_stop();
		$_inhibit_bell = 1;
		$_inhibit_window = $witem->window();
	}
}
Irssi::signal_add_first('window item hilight', \&maybe_inhibit_witem_hilight);

sub inhibit_win_hilight {
	my ($win) = @_;
	Irssi::signal_stop();
	Irssi::signal_emit('window dehilight', $win);
}

sub maybe_inhibit_win_hilight {
	my ($win, $oldlevel) = @_;
	return unless $win;
	if ($_inhibit_debug_activity) {
		inhibit_win_hilight($win);
	}
	elsif ($_inhibit_window && $win->{'refnum'} == $_inhibit_window->{'refnum'}) {
		inhibit_win_hilight($win);
	}
	else {
		$oldlevel = 0 unless $oldlevel;
		my $newlevel = $win->{'data_level'};
		return if ($newlevel <= $oldlevel);

		my $wname = $win->{'name'};
		my $threshold = get_win_threshold($wname);
		my $inhibit = $newlevel > 0 && $newlevel < $threshold;
		debugprint(($wname?$wname:'(unnamed)').": window \"$wname\" $oldlevel → $newlevel (".($inhibit ? "< $threshold, inhibit" : ">= $threshold, pass").')');
		inhibit_win_hilight($win) if $inhibit;
	}
}
Irssi::signal_add_first('window hilight', \&maybe_inhibit_win_hilight);

sub maybe_inhibit_beep {
	Irssi::signal_stop() if $_inhibit_bell;
}
Irssi::signal_add_first('beep', \&maybe_inhibit_beep);

### SAVING AND LOADING #########################################################

sub get_mappings_fh {
	my ($filename) = @_;
	my $fh;
	if (-e $filename) {
		open($fh, $filename) || die "Cannot open mappings file: $!";
	}
	else {
		open($fh, "+>$filename") || die "Cannot create mappings file: $!";

		my $ftw = from_data_level($fallback_window_threshold);
		my $ftc = from_data_level($fallback_channel_threshold);
		my $ftq = from_data_level($fallback_query_threshold);
		print $fh <<"EOF";
# ctrlact mappings file (version:$VERSION)
#
# type: window, channel, query
# name: full name to match, /regexp/, or * (for all)
# min.level: none, messages, hilights, all, or 1,2,3,4
#
# type	name	min.level


# EXAMPLES
#
### only indicate activity in the status window if messages were displayed:
# window	(status)	messages
#
### never ever indicate activity for any item bound to this window:
# window	oubliette	none
#
### indicate activity on all messages in debian-related channels:
# channel	/^#debian/	messages
#
### display any text (incl. joins etc.) for the '#madduck' channel:
# channel	#madduck	all
#
### otherwise ignore everything in channels, unless a hilight is triggered:
# channel	*	hilights
#
### make somebot only get your attention if they hilight you:
# query	somebot	hilights
#
### otherwise we want to see everything in queries:
# query	*	all

# DEFAULTS:
# window	*	$ftw
# channel	*	$ftc
# query	*	$ftq

# vim:noet:tw=0:ts=16
EOF
		Irssi::print("ctrlact: created new/empty mappings file: $filename");
	}
	return $fh;
}

sub load_mappings {
	my ($filename) = @_;
	@window_thresholds = @channel_thresholds = @query_thresholds = ();
	my $fh = get_mappings_fh($filename);
	while (<$fh>) {
		next if m/^\s*(?:#|$)/;
		m/^\s*(\S+)\s+(\S+)\s+(\S+)\s*$/;
		push @window_thresholds, [$2, $3] if match($1, 'window');
		push @channel_thresholds, [$2, $3] if match($1, 'channel');
		push @query_thresholds, [$2, $3] if match($1, 'query');
	}
	close($fh) || die "Cannot close mappings file: $!";
}

sub cmd_load {
	Irssi::print("ctrlact: loading mappings from $map_file");
	load_mappings($map_file);
	$changed_since_last_save = 0;
}

sub cmd_save {
	error("saving not yet implemented");
	return 1;
}

sub cmd_list {
	Irssi::print("ctrlact: window mappings");
	print CLIENTCRAP get_mappings_table(@window_thresholds);
	Irssi::print("ctrlact: channel mappings");
	print CLIENTCRAP get_mappings_table(@channel_thresholds);
	Irssi::print("ctrlact: query mappings");
	print CLIENTCRAP get_mappings_table(@query_thresholds);
}

sub parse_args {
	my (@args) = @_;
	my @words = ();
	my $typewasset = 0;
	my $max = 0;
	my $type = undef;
	foreach my $arg (@args) {
		if ($arg =~ m/^-(windows?|channels?|quer(?:ys?|ies))/) {
			if ($typewasset) {
				error("can't specify -$1 after -$type");
				return 1;
			}
			$type = 'window' if $1 =~ m/^w/;
			$type = 'channel' if $1 =~ m/^c/;
			$type = 'query' if $1 =~ m/^q/;
			$typewasset = 1
		}
		elsif ($arg =~ m/^-/) {
			error("Unknown argument: $arg");
		}
		else {
			push @words, $arg;
			$max = length $arg if length $arg > $max;
		}
	}
	return ($type, $max, @words);
}

sub cmd_query {
	my ($data, $server, $item) = @_;
	my @args = shellwords($data);
	my ($type, $max, @words) = parse_args(@args);
	$type = $type // 'channel';
	foreach my $word (@words) {
		my $t = get_specific_threshold($type, $word);
		printf CLIENTCRAP "ctrlact $type map: %*s → %d (%s)", $max, $word, $t, from_data_level($t);
	}
}

sub cmd_show {
	my ($data, $server, $item) = @_;
	my @args = shellwords($data);
	my ($type, $max, @words) = parse_args(@args);
	$type = $type // 'all';

	if ($type eq 'channel' or $type eq 'all') {
		print_levels_for_all('channel', Irssi::channels());
	}
	if ($type eq 'query' or $type eq 'all') {
		print_levels_for_all('query', Irssi::queries());
	}
	if ($type eq 'window' or $type eq 'all') {
		print_levels_for_all('window', Irssi::windows());
	}
}

sub autosave {
	cmd_save() if ($changed_since_last_save);
}

sub UNLOAD {
	autosave();
}

Irssi::signal_add('setup saved', \&autosave);

Irssi::command_bind('ctrlact help',\&cmd_help);
Irssi::command_bind('ctrlact reload',\&cmd_load);
Irssi::command_bind('ctrlact load',\&cmd_load);
Irssi::command_bind('ctrlact save',\&cmd_save);
Irssi::command_bind('ctrlact list',\&cmd_list);
Irssi::command_bind('ctrlact query',\&cmd_query);
Irssi::command_bind('ctrlact show',\&cmd_show);

Irssi::command_bind('ctrlact' => sub {
		my ( $data, $server, $item ) = @_;
		$data =~ s/\s+$//g;
		if ($data) {
			Irssi::command_runsub('ctrlact', $data, $server, $item);
		}
		else {
			cmd_help();
		}
	}
);
Irssi::command_bind('help', sub {
		$_[0] =~ s/\s+$//g;
		return unless $_[0] eq 'ctrlact';
		cmd_help();
		Irssi::signal_stop();
	}
);

cmd_load();
