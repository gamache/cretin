#!/usr/bin/perl
use strict;
#use warnings;
#use diagnostics;

###############################################################################
#
# Cretin version 0.5
# CD Ripper, Encoder and Tagger with an Inoffensive Name
#
# formerly Choad, until Sourceforge declined to host a project of that title
#
#  ,   copyright 2007        pete gamache   email: gmail!gamache
# (k)  all rights reversed                  http://cretin.sf.net
#
# This software is released under the Perl Artistic License, available at:
# http://dev.perl.org/licenses/artistic.html
#
###############################################################################

package Cretin; 

our $VERSION = '0.5b5';

use Cretin::Song;

use UNIVERSAL qw(isa);
use POSIX ":sys_wait_h";
use Fcntl ':flock';

__PACKAGE__->main (@ARGV) unless caller;


sub main {
	my $class = shift;
##	cmd line args are in @_

	my $c = new Cretin;
	
	$c->read_cfg_file ("/etc/cretinrc");
	$c->read_cfg_file ("$ENV{HOME}/.cretinrc");
	
		
	while ($_[0] =~ /^-/) {
		my $opt = shift;
		
		## -h: help
		if ($opt =~ /-h/i) {
			print usage(); 
			exit 0; 
		}
		
		## -rip: set ripper   WAAAY DEPRECATED DUDE
		elsif ($opt =~ /-rip$/) {
			$c->cfg('cfg.rip', shift);
		}
		
		## -enc: set encoder  YO THIS TOO
		elsif ($opt =~ /-enc$/) {
			$c->cfg('cfg.enc', shift);
		}
		
		## -c: set config option
		elsif ($opt eq '-c') {
			my ($key, $val) = (shift, shift) or die "-c: needs two arguments";
			$c->cfg ($key, $val) or die "-c: $!";
		}
		
		## -f: read config file
		elsif ($opt eq '-f') {
			$c->read_cfg_file (shift) or die "-f: $!";
		}
		
		## -recover: requeue tasks in enclog
		elsif ($opt =~ /-recover/) {
			$c->recover;
		}
		
		else {
			print STDERR usage();
			print STDERR "Invalid option: $opt\n";
			exit 1;
		}
	}
	
	
	my $mode = shift;
	$mode ||= 'both';
	$mode = lc $mode;
	

	if ($mode !~ /(rip|enc|both|nop)/) {
		print STDERR usage(), "Invalid mode: $mode\n";
		exit 1;
	}

	
	my $encpid;
	
	do {
		if ($mode =~ /(rip|both)/) {
			$c->init_from_disc;
			$c->rip_and_queue_disc;
		}
		
		if ($mode =~ /(enc|both)/) {
			if (!$encpid  ||  waitpid ($encpid, WNOHANG) > 0) {
					$encpid = $c->spawn_encoder;
			}
		}
		
		if ($mode =~ /(rip|both)/) {
			$c->eject;
		}
		
		$c->clear;	# prevent leaks due to circular references
		
		if ($mode =~ /(rip|both)/) {
			print "\n\nPress Return to rip another disc, or Ctrl-C to quit.\n";
		}
		elsif ($mode =~ /enc/) {
			print "\n\nWait here until the encoder engine is done.\n";
			waitpid ($encpid, 0);
			exit 0;
		}
		elsif ($mode =~ /nop/) {
			print "Exiting.\n";
			exit 0;
		}
	} 
	while ($c->{cfg}{repeat}==1  ||  <STDIN>);
	
	exit 0;
}	
	

sub usage {<<EOT
Cretin $VERSION   copyright 2007 pete gamache   http://cretin.sf.net
Usage: $0 [options] [mode]

Options:
 -h              Print help message
 -c xx.yy zz     Set config directive xx.yy to zz
 -f filename     Read config file at filename
 -rip r          Select ripper r (default: cdp)
 -enc e,f,g      Select encoders e, f and g (default: lame)
 -recover        Move tasks from enclog to encq
       
Modes:
 rip   Rip a disc, and queue it for encoding; repeat
 enc   Encode items in the encoding queue
 both  Rip, queue, spawn encoder engine; repeat.  This is the default mode.
 nop   Rip nothing, queue nothing, encode nothing, exit.

EOT
}

sub new {
	my $class = shift;
	my $self = {};
	bless $self, $class;
	
	$self->{version} = $VERSION;
	$self->{cfg} = {
		rootdir	=>	"$ENV{HOME}/cretin",	# root for all files created
		
		ripdir	=>	'rips',					# appended (with slashes) to 
											# rootdir for all rippers
		encdir	=>	'encs',					# same as above, for encoders
		
		maxenc	=>	2,						# max concurrent encoders
		
		rip		=>	'cdp',					# selected ripper
		enc		=>	'lame, flac',			# /[, ]+/ list of encoders
		
		rips	=>	{},						# holds ripper definitions
		encs	=>	{},						# holds encoder definitions
		
		songs	=>	[],						# arrayref of Cretin::Song
		
		encq	=>	'encq',
		enclog	=>	'enclog',
		
		ejectcmd => '',
		repeat => 0,
		debug	=> 1,
		
		dirfmt	=>	'%A[64]/%L[64]',		# format string for new dirs
		filefmt	=>	'%n[2] %T[64]',			# format string for new files
		nfofile	=>	'tracks.nfo',
		
		keep_encoder_running	=>	0,

		
	};
	
	
	chomp(my $h = `hostname`);
	
	$self->{var} = {
		hostname				=>	$h
	};
	
	
	$self->def_rips;
	$self->def_encs;
	
	return $self;
}


## clear
## Clears the list of songs.  Destroys each Cretin::Song to avoid memory leaks. 

sub clear {
	my $self = shift;	
	foreach (@{$self->{songs}}) { $_->destroy }
}


## new_song (%args)
## Creates a new Cretin::Song and adds it to the list.

sub new_song {
	my $self = shift;
	my %args = @_;

	$args{cretin} = $self;
	
	new Cretin::Song (%args);
}	







#### "public" methods
#### called from main()

## init_from_disc ()
## Fills $self up with disc information and a list of Cretin::Songs
## from a CD.

sub init_from_disc {
	my $self = shift;
	
	print "\nCretin: Getting CD table of contents.\n";

	$self->{toc} = $self->ripper->{get_toc}->($self);
	
	my $waiting;
	while (!$self->{toc}) {
		print "\nCretin: No disc found; waiting.\n" unless $waiting++;
		sleep 10;
		$self->{toc} = $self->ripper->{get_toc}->($self);
	}
	
	print "\nCretin: Getting CD info...\n";
	$self->{info} = $self->get_cddb_info;
}


## rip_disc ()
## Rips each Cretin::Song in the list.

sub rip_disc {
	my $self = shift;
	
	print "\nRipper: Ripping disc...\n";
	foreach my $song (@{$self->{songs}}) {
		$song->rip;
		print "\n";
		sleep 1;	# make it easy to Ctrl-C out of Cretin
	}
	print "\nRipper: Finished with disc.\n";
}

## queue_disc ()
## Queues each Cretin::Song in the list for encoding.

sub queue_disc {
	my $self = shift;

	foreach my $song (@{$self->{songs}}) {
		$song->queue;
	}
}

sub rip_and_queue_disc {
	my $self = shift;
	
	foreach my $song (@{$self->{songs}}) {
		$song->rip_and_queue;
		print "\n";
		sleep 1;	# make it easy to Ctrl-C out of Cretin

	}
}	
	


## spawn_encoder ()
## Spawns a subprocess which will control encoding operations.
## Returns PID of subprocess.

sub spawn_encoder {
	my $self = shift;
	my $pid = $self->launch_task( sub {
		print "\nCretin: Launching encoding engine.\n";
		$self->encode;
		print "\nCretin: Encoding engine exiting.\n";
	} );
}


sub eject {
	my $self = shift;
	system $self->{cfg}{ejectcmd};
}		




#### encoding
####


## encode ()
## Encode songs from the queue until the queue is empty, then return.

sub encode {
	my $self = shift;
	
	print "\nEncoder: Encoder engine starting.\n";

	my $kids = [];
	
	do {
		my $living_kids = [];
		foreach (@$kids) {
			if (waitpid ($_, WNOHANG) == 0) {
				push @$living_kids, $_;
			} else {
				print "\nEncoder: Process $_ is finished.\n";
			}
		}
		$kids = $living_kids;

		while (scalar @$kids < $self->{cfg}{maxenc}) {
			my $task = $self->get_enc_task;
			if ($task) {
				my $kp = $self->launch_task ($task);
				print "\nEncoder: Launched process $kp.\n";
				push @$kids, $kp;
			} else {
				last;
			}
		}
				
		sleep 5;
	}
	while (scalar @$kids > 0 ||  $self->{cfg}{keep_encoder_running} > 0);
	
	print "\nEncoder: Encoder engine exiting.\n";
}


## get_enc_task ()
## Returns a subroutine reference to the next encoding task.

sub get_enc_task {
	my $self = shift;
		
	open ENCQ, "<", $self->encq or return undef;
	flock (ENCQ, LOCK_EX);
	my $encq = join '', (<ENCQ>);
	flock (ENCQ, LOCK_UN);
	close ENCQ;

	my @tasks = split /\n{2,}/, $encq;
	return undef if scalar @tasks < 1;
	
	my $task = shift @tasks;
	
	open ENCQ, ">", $self->encq or die $!;
	flock (ENCQ, LOCK_EX);
	foreach (@tasks) {print ENCQ "$_\n\n"}
	flock (ENCQ, LOCK_UN);
	close ENCQ;
	
	my @lines = split /\n/, $task;
	
	my $enc = shift @lines;
	if (!defined $self->{encs}{$enc}) {
		warn "No such encoder $enc";
		return undef;
	}
	
	my @args;
	foreach (@lines) {
		if (/^\t (\S+) \t (.+?) \s*$/x) {
			push @args, $1, $2;
		}
	}
	my $song = $self->new_song (@args);
	return sub { $self->{encs}{$enc}{enc_song}->($song) }
}


## recover ()
## Remove all tasks from log of running encoder tasks, and requeue them.

sub recover {
	my $self = shift;
	
	open LOG, '<', $self->enclog or return undef;
	my @tasks = split /(?<=\n)\n+/, (join '', (<LOG>));
	close LOG;
	
	open ENCQ, '>>', $self->encq or return undef;
	flock (ENCQ, LOCK_EX);
	foreach (@tasks) {
		s/^.+$//m;			# eat 1st line
		s/^\n+//s;			# and its \n
		print ENCQ "$_\n";
	}
	flock (ENCQ, LOCK_UN);
	close ENCQ;
	
	open LOG, '>', $self->enclog or return undef;
	close LOG;
	
	return 1;
}


## launch_task ($subref, @args)
## Forks a subprocess, which executes $subref->(@_) and exits.
## Returns pid of child process.

sub launch_task {
	my $self = shift;
	my $task = shift;
	
	my $pid = fork;
	if ($pid == 0) {
		&$task;			# task gets @_
		exit 0;
	} else {
		return $pid;
	}
}
	
				



#### ripper code
#### also see Cretin::Song


## def_rips ()
## Here be ripper definitions.
## Rippers are expected to support the following interface:
##
## $ripper->{get_toc}->()
## Return the CD's table of contents, as array or arrayref (depending on 
## context) of strings of the form: "$tracknum $min $sec $frames".
##
## $ripper->{rip_song}->(Cretin::Song)
## Rip the given Cretin::Song and store it accordingly.


sub def_rips {
	my $self = shift;

	## cdparanoia
	
	my $cdp = 'cdp';
	
	$self->{rips}{$cdp} = {
		dir		=>	'',
		cmd		=> 	'cdparanoia',
		flags	=>	'',
	};
	
		

	$self->{rips}{$cdp}{get_toc} = sub {
		my $self = shift;	# Cretin
		my $cmd = join ' ',
			$self->rips->{$cdp}{cmd},
			$self->rips->{$cdp}{flags},
			'-Q',
			'2>&1'
		;
		
		my @q = `$cmd`;
		my @toc;
		
		while ($_ = shift @q) { last if /===============/ }
		while ($_ = shift @q) { 
			last unless /	\s* (\d+)\. \s+ \d+ \s+ 	# track number
							\[ \d\d \: \d\d \. \d\d \]	
							\s+ \d+ \s+ 
							\[(\d\d)\:(\d\d)\.(\d\d)\] 	# mm ss ff
						/x;	
			push @toc, "$1 $2 $3 $4";
		}
		if (/TOTAL \s+ \d+ \s+ \[(\d\d):(\d\d)\.(\d\d)\]/x) {
			push @toc, "999 $1 $2 $3";
		} else {
			return undef;
		}
		
		return wantarray ? @toc : \@toc;
	};
	
	
	$self->{rips}{$cdp}{rip_song} = sub {
		my $self = shift;	# Cretin::Song

		my $reldir = join '',
			$self->cretin->{cfg}{ripdir}, '/',
			$self->cretin->ripper->{dir}, '/',
			$self->{fmtdir}, '/';
			
		my $dir = $self->cretin->{cfg}{rootdir} . '/' . $reldir;
		
		my $qdir = quotemeta $dir;
		system ("mkdir -p $qdir");# or die $!;
		
		my $vcmd = $self->cretin->rips->{$cdp}{cmd} . " --version";
		my @vary = split /\n/, `$vcmd 2>&1` or die $!;
		my $vstr = $vary[0];
		
		open NFO, ">", "$dir/tracks.nfo" or die $!;
		print NFO $self->{nfo};
		print NFO "\n",
				"ripped with $vstr\n",
				"with flags: ", $self->cretin->rips->{$cdp}{flags}, "\n";
		close NFO;
		
		$self->set_nfofile("$reldir/tracks.nfo");

		my $cmd = join (' ',
			$self->cretin->rips->{$cdp}{cmd},
			$self->cretin->rips->{$cdp}{flags},
			$self->{tnum},
			join ('',
				$qdir,
				quotemeta $self->{fmtfile},
				'.wav'
			)
		);
		system $cmd;
		
		$self->set_path (join '', $reldir, '/', $self->{fmtfile}, '.wav');
	};

	$self;
} 


#### encoder code
#### some important routines also exist in Cretin::Song

## def_encs
## Encoder definitions.  Pretty self-explanatory.

sub def_encs {
	my $self = shift;
	
	
	my $lame = 'lame';
	$self->mkenc (
		name 	=>	$lame,
		dir		=>	$lame,
		
		cmd		=>	'lame',
		flags	=>	'',
		ext		=>	'mp3',
		
		opt_version	=>	'--version',
		opt_artist	=>	'--ta ',
		opt_album	=>	'--tl ',
		opt_title	=>	'--tt ',
		opt_tnum	=>	'--tn ',
		opt_year	=>	'--ty ',
		opt_genre	=>	'--tg ',
		
		enc_cmd 	=>	[
							'__INFILE__', 
							'__OUTFILE__'
						],
	);
		
	
	my $flac = 'flac';
	$self->mkenc (
		name 	=>	$flac,
		dir		=>	$flac,
		
		cmd		=>	'flac',
		flags	=>	'',
		ext		=>	'flac',
		
		opt_version	=>	'--version',
		opt_artist	=>	'-T ARTIST=',
		opt_album	=>	'-T ALBUM=',
		opt_title	=>	'-T TITLE=',
		opt_tnum	=>	'-T TRACKNUMBER=',
		opt_year	=>	'-T DATE=',
		opt_genre	=>	'-T GENRE=',
		
		enc_cmd 	=>	[
							'-o', '__OUTFILE__',
							'__INFILE__', 
						],
	);


	my $ogg = 'ogg';
	$self->mkenc (
		name	=>	$ogg,
		dir		=>	$ogg,
		cmd		=>	'oggenc',
		flags	=>	'',
		ext		=>	'ogg',
		
		opt_version	=>	'--version',
		opt_artist	=>	'-a ',
		opt_album	=>	'-l ',
		opt_title	=>	'-t ',
		opt_tnum	=>	'-N ',
		opt_year	=>	'-d ',
		opt_genre	=>	'-G ',
		
		enc_cmd 	=>	[
							'-o', '__OUTFILE__',
							'__INFILE__'
						],
	);
	
	
	my $shn = 'shn';
	$self->mkenc (
		name	=>	$shn,
		dir		=>	$shn,
		cmd		=>	'shorten',
		flags	=>	'',
		ext		=>	'shn',
		
		opt_version	=>	'--version',
		# shorten sucks, so it doesn't give us any tagging facilities
		
		enc_cmd		=>	[
							'__INFILE__',
							'__OUTFILE__'
						],
	);
	
	
	my $faac = 'faac';
	$self->mkenc (
		name	=>	$faac,
		dir		=>	$faac,
		cmd		=>	'faac',
		flags	=>	'',
		ext		=>	'm4a',
		
		opt_version	=>	'--version',
		opt_artist	=>	'--artist ',
		opt_album	=>	'--album ',
		opt_title	=>	'--title ',
		opt_tnum	=>	'--track ',
		opt_year	=>	'--year ',
		opt_genre	=>	'--genre ',
		
		enc_cmd 	=>	[
							'-o', '__OUTFILE__',
							'__INFILE__'
						],
	);
	

	
	return $self;
}


## mkenc (%args)
## Defines an encoder.

sub mkenc {
	my $self = shift;
	my %args = @_;
	
	die "we need a name!" unless my $enc = $args{name};
	
	$self->{encs}{$enc} = {};
	
	foreach (keys %args) {
		$self->{encs}{$enc}{$_} = $args{$_};
	}

	$self->{encs}{$enc}{enc_song} = sub {
		my $self = shift;	# Cretin::Song
		
		$self->_enc_mkdir ($enc) or die $!;

		$self->_enc_mknfo ($enc) or die $!;
			
		$self->_enc_exec ($enc) or die $!;
	};
}




#### config handling code
####


## read_cfg_file ($filename)
## Does what you think.

sub read_cfg_file {
	my $self = shift;
	my $fn = shift;
	
	open CFG, '<', $fn or return undef;
	for (<CFG>) {
		next if /^#/;					# ignore comments
		next if /^\s*$/;				# and whitespace
		$self->cfg (split /[\t\n]+/);
	}
	close CFG;

	2.718281828459045;
}


## cfg ($key, $val)
## Sets a config variable, or more generally an element within the $self hashref.  
## $key is a dot-separated hashref path under $self.
## You must be cautious.

sub cfg {
	my $self = shift;
	my $key = shift;  return undef if $key eq '';
	my $val = shift;
	
	if ($key=~/[;\{\}\$]/) {
		warn "cfg: Key $key has invalid characters; skipping.";
		return undef;
	}
	
	## change x to {x} and x.y.z to {x}{y}{z}
	$key =~ s|([^\.]+)|\{$1\}|g;
	$key =~ s|\.||g;
	
	my $qval = quotemeta $val;
	my $perl = qq|\$self->$key = "$qval";|;
	eval $perl;

	3.141592653589;
}




#### cddb

sub get_cddb_info {
	my $self = shift;

	use CDDB;
	my $cddbp = new CDDB (
		Host	=>	'freedb.freedb.org',
		Port	=>	8880,
		Login	=>	'choad'
	) or die $!;
	
	my (	
		$cddbp_id,      # used for further cddbp queries
		$track_numbers, # padded with 0's (for convenience)
		$track_lengths, # length of each track, in MM:SS format
		$track_offsets, # absolute offsets (used for further cddbp queries)
		$total_seconds  # total play time, in seconds (for cddbp queries)
	) = $cddbp->calculate_id(@{$self->{toc}});
	
	my @discs = $cddbp->get_discs($cddbp_id, $track_offsets, $total_seconds);
	my ($genre, $id, $artistandalbum);
	
	# FIXME this next bit is not flexible
	foreach my $disc (@discs) {
		($genre, $id, $artistandalbum) = @$disc;
	}
	
	my $disc_info = $cddbp->get_disc_details($genre, $id);


#	foreach (keys %$disc_info) {
#		print "$_ $disc_info->{$_}\n";
#	}

	$artistandalbum =~ m|([^/]+) / (.+)|;
	my ($artist, $album) = ($1, $2);

	my $nfo = <<EOT;
artist\t$artist
album\t$album
year\t$disc_info->{dyear}
genre\t$disc_info->{dgenre}
cddb_id\t$id
cddb_genre\t$genre

EOT

	foreach (@$track_numbers) {
		$nfo .= join '',
			"$_  ",
			$track_lengths->[$_-1], '  ',
			$disc_info->{ttitles}->[$_-1],
			"\n";
	}
	
	$nfo .= "\nharnessed by cretin " . $self->{version} . 
			"  http://cretin.sf.net\n";
	
	$self->{info} = {
		artist		=>	$artist,
		album		=>	$album,
		year		=>	$disc_info->{dyear},
		genre		=>	$disc_info->{dgenre},
		titles		=>	$disc_info->{ttitles},
		ttimes		=>	$track_lengths,
		tnums		=>	$track_numbers,
		nfo		=>	$nfo,
	};
		
	$self->{songs} = [];
	
	my $i=0;
	foreach (@{$self->{info}{titles}}) {
		push @{$self->{songs}}, $self->new_song (
			title	=> $_,
			ttime	=> $self->{info}{ttimes}[$i],
			tnum	=> $self->{info}{tnums}[$i],
			
			%{$self->{info}}
		);
		$i++;
	}
	
	
	
}




#### getters

sub rips { $_[0]->{rips} }
sub encs { $_[0]->{encs} }
sub root { $_[0]->{cfg}{rootdir} }

sub encq {
	my $self = shift;
	join ('',
		$self->root, '/',
		$self->{cfg}{encq}
	)
}

sub enclog {
	my $self = shift;
	join ('',
		$self->root, '/',
		$self->{cfg}{enclog}
	)
}

sub ripper { 
	my $self = shift;
	$self->rips->{$self->{cfg}{rip}};
}


sub encoders {
	my $self = shift;
	my @encs;
	foreach my $encname (split /[, ]+/, $self->{cfg}{enc}) {
		push @encs, $self->{encs}{$encname};
	}
	wantarray ? @encs : \@encs;
}



#### miscellaneous

sub debug {
	my $self = shift;
	foreach (@_) {
		print STDERR "$_\n" if $self->{cfg}{debug} > 0;
	}
}


#### static methods
####


## mkargs (%args)
## Returns a command-line safe string version of the given arguments.
## Keys (flags) must include a trailing space if there is to be a space between
## the flag and its value!

sub mkargs {
	my %args = @_;
	
	my $str;
	foreach (keys %args) {
		if ($args{$_} && $_) {
			$str .= "$_" . (quotemeta $args{$_}) . " ";
		}
	}
	
	return $str;
}


'11:11:41 <ralph> somebody said cretin was *SO CLOSE* to doing something useful'



__END__

=head1 NAME

Cretin - CD Ripper, Encoder and Tagger with an Inoffensive Name

=head1 SYNOPSIS

cretin [I<options>] [I<mode>]

=head1 DESCRIPTION

Cretin is a high-performance CD reencoder, handling the ripping, encoding and tagging of audio compact discs to multiple file formats. Cretin can operate standalone; however, its power and purpose are unleashed in distributed and multiprocessed environments.  Cretin is highly customizable and supports the use of many encoding and ripping utilities.

Cretin is a command-line application, for maximum flexibility, portability and purity of design.

=head1 SUPPORTED TOOLS

=over

=item Rippers
     
cdp (cdparanoia)

=item Encoders
  
lame, flac, ogg, faac, shn (shorten)

=back

=head1 MODES

Cretin has four modes of operation, between zero and one of which must
be specified last on the command line:

=over 6

=item rip   

Rip a CD, queue it for encoding, and eject the disc.  Repeat.

=item enc   

Encode songs from the queue until the queue is empty.  Exit.

=item both  

Rip a cd, queue it for encoding, launch encoder subprocess, eject
the disc.  Repeat.  This is the default mode of operation.

=item nop   

No operation.  Do nothing and exit.  This mode is mostly useful
in conjunction with the "-recover" option.

=back

=head1 OPTIONS

Here is a summary of the options the "cretin" command accepts:

=over 

=item -h, -help, --help, ---HEEELLLLLP and anything else matching /-h/i

Print a short help message and exit.

=item -c I<cfg.var> I<value>

Set configuration variable I<cfg.var> to I<value>.  May be specified multiple times.

=item -f I<cfgfile>

Read config file I<cfgfile>.  May be specified multiple times.

=item -recover

Recover from a crashed or interrupted session.  This option will
requeue songs which did not finish encoding.  A warning: do not use
this option when there are running encoders.  There will be no
lasting damage, but unnecessary computation will be performed.

=back

=head1 CONFIGURATION VARIABLES

Config variables enable heavy customization of Cretin's operation.
Here is a list of variables which may be set by the user:

=over

=item cfg.rootdir

Root directory, under which all Cretin operations take place.

=item cfg.encq

Filename, within cfg.rootdir, of encoding queue.

=item cfg.enclog

Filename, within cfg.rootdir, of in-process encoding log.

=item cfg.ripdir

Directory, within cfg.rootdir, under which all ripping operations
take place.

=item cfg.encdir

Directory, within cfg.rootdir, under which all encoding operations
take place.

=item cfg.ripdir

Directory, within cfg.rootdir, under which all ripping operations
take place.

=item cfg.rip

Selected ripper.

=item cfg.enc

Comma-separated list of selected encoders.

=item cfg.maxenc

Number of encoding processes to spawn at once.

=item cfg.dirfmt

Format string for artist and album directory names.

=item cfg.filefmt

Format string for song filenames.

=item cfg.ejectcmd

Command to eject a CD.  Defaults to the empty string (no ejection).

=item cfg.repeat

Set to 1 to start ripping next disc immediately after a disc finishes, without
pressing Return.  Note: make sure you have specified a valid ejectcmd above!

=item cfg.keep_encoder_running

Set to 1 to prevent the encoder engine from exiting when the encoding queue
is empty

=item rips.I<XXX>.cmd, encs.I<XXX>.cmd

Command path for ripper or encoder I<XXX>.

=item rips.I<XXX>.flags, encs.I<XXX>.flags

Command flags for ripper or encoder I<XXX>.

=item rips.I<XXX>.dir, encs.I<XXX>.dir

Directory, within cfg.ripdir or cfg.encdir, under which all opera-
tions for ripper or encoder I<XXX> take place.

=item rips.I<XXX>.ext, encs.I<XXX>.ext

Filename extension for ripper or encoder I<XXX>.

=back

=head1 CONFIG FILES

By default, Cretin reads F</etc/cretinrc> and F<~/.cretinrc> as config files
at startup.  Other config files may be specified by the -f option.

Config files must adhere to the following syntax:

=over

=item *

Lines consisting only of whitespace and lines beginning with # are
ignored.

=item *

All other lines begin with the name of the config variable.

=item *   

If the variable is being set to a non-empty value, the variable
name is followed by one or more tab characters, followed by the
value.  Quoting or backslashing is unnecessary.

If the variable is being set to an empty value, the line may end
after the variable name.

=back

=head1 FORMAT STRINGS

Naming of directories and files may be controlled by customizing
Cretin's format strings, config variables "cfg.dirfmt" and
"cfg.filefmt".  Format strings are string containing tokens which obey
the following grammar:

=over

=item *

All tokens begin with a % character.

=item *

The next character in the token is one of the following letters:

=over 6

=item a, A  

Artist name.

=item l, L  

Album name.

=item t, T  

Track name.

=item n, N  

Track number.

=back

The case of the letter is significant; a lowercase letter will
force items into lowercase, while an uppercase letter will leave
capitalization untouched.

=item *

Optionally, the character _ may be specified next.  This will
replace space characters with underscores.

=item *

Optionally, a length of the form [I<nn>] may be specified last.  In
the case of letters A, L and T, the length will be enforced as a
maximum; in the case of N, the length will be enforced as a minimum.

Cretin's default cfg.dirfmt is "%A[64]/%L[64]", and cfg.filefmt
defaults to S<"%n[2] %T[64]">.

=back

=head1 TIPS AND TRICKS

=head2 Distributed Ripping and Encoding

Using the networked filesystem of your choice (NFS, AFP, SMB, etc.),
share a directory among all desired computers.  Set cfg.rootdir on each
computer to point to the directory (or a subdirectory).  Ensure that
all directory-related variables among machines are set in unison.  You
may now rip and encode on multiple computers.

=head2 Multiprocessing

On each machine, set the cfg.maxenc variable equal to (or just higher
than) the number of CPU cores you'd like to keep busy.

=head2 Delayed Encoding

Run "cretin rip" first, then don't run "cretin enc" until you are
ready.

=head1 AUTHOR

Pete Gamache, gamache!@#$%gmail.com.

=head1 COPYRIGHT AND LICENSE

Cretin is copyright 2007, Pete Gamache.

Cretin is released under the Perl Artistic License, whose text is
available at: L<http://dev.perl.org/licenses/artistic.html>.

=head1 BUGS AND KNOWN ISSUES

FreeDB lookup may be incorrect if there are multiple records returned
from the database.
