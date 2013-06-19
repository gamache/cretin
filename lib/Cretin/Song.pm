#!/usr/bin/perl
use strict;
#use warnings;

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



package Cretin::Song;

use Cretin;
use Fcntl ':flock';

sub new {
	my $class = shift;
	my $self = {@_};
	bless $self, $class;

	
	$self->{fmtdir} = $self->fmt ($self->cretin->{cfg}{dirfmt});
	$self->{fmtfile} = $self->fmt ($self->cretin->{cfg}{filefmt});
	
	return $self;
}

sub destroy {
	my $self = shift;
	foreach (keys %$self) { delete $self->{$_} }		
}

sub cretin	{ $_[0]->{cretin}	}

sub artist	{ $_[0]->{artist} 	}
sub album	{ $_[0]->{album}	}
sub title	{ $_[0]->{title}	}
sub tnum	{ $_[0]->{tnum}		}
sub ttime	{ $_[0]->{ttime}	}
sub year	{ $_[0]->{year}		}
sub genre	{ $_[0]->{genre}	}


# static method
sub printhr {
	my $hashref = shift;
	foreach (keys %$hashref) {
		print "$_\t", $hashref->{$_}, "\n";
	}
}

sub set_path {
	my $self = shift;
	$self->{path} = shift;
}

sub set_nfofile {
	my $self = shift;
	$self->{nfofile} = shift;
}


sub rip {
	my $self = shift;
	print "\nCretin: Ripping song...\n";
	$self->cretin->ripper->{rip_song}->($self);
	print "\nCretin: Finished ripping song.\n";
}

sub queue {
	my $self = shift;

	open ENCQ, ">>", $self->cretin->encq or die $!;
	flock (ENCQ, LOCK_EX);
	
	foreach my $enc ($self->cretin->encoders) {
		print ENCQ $enc->{name}, "\n";
		print ENCQ $self->serialize, "\n";
	}
	
	flock (ENCQ, LOCK_UN);
	close ENCQ;
}

sub rip_and_queue {
	my $self = shift;
	$self->rip;
	$self->queue;
}

sub serialize {
	my $self = shift;
	
	my $str;
	KEY:
	foreach (keys %$self) {
		for my $k (qw(nfo cretin titles tnums ttimes)) {
			next KEY if $_ eq $k;
		}
		$str .= "\t$_\t" . $self->{$_} . "\n";
	}
	
	return $str;
}

sub fmt {
	my $self = shift;
	my $fmtstr = shift;
	
	my $str = '';
	
	foreach my $substr (split /(?<!\\)(?=%)/, $fmtstr) { # 0-1 token per substr
		if ($substr =~ s/^ (?<!\\)
							(
								\% 
		 						([altny])
		 						(_?)
		 						(?: \[ (\d+) \] )?
		 					)	
						/__TOKEN__/xi) {
			my ($token, $field, $underscore, $len) = ($1, $2, $3, $4);
			
			my $fstr;
			
			if 		($field =~ /a/i) { $fstr = $self->{artist}	}
			elsif 	($field =~ /l/i) { $fstr = $self->{album} 	}
			elsif 	($field =~ /t/i) { $fstr = $self->{title} 	}
			elsif 	($field =~ /n/i) { $fstr = $self->{tnum} 	}
			elsif 	($field =~ /y/i) { $fstr = $self->{year} 	}

			$fstr =~ s|[:/\\\;]|-|g;	# strip pesky metacharacters

			if (lc $field eq $field) {
				$fstr = lc $fstr;
			}

			if ($underscore) {
				$fstr =~ s/\s/_/g;
			}
			
			if ($len && $len > 0) {
				if ($field =~ /n/i) {
					$fstr = sprintf "%.${len}d", $fstr;
				} else {
					$fstr = sprintf "%.${len}s", $fstr;
				}
			}
			
			$substr =~ s/__TOKEN__/$fstr/;
		}
		
		$str .= $substr;
	}
	
	$str =~ s/\\\%/%/g;	# \% becomes %
	return $str;
}

sub log_enc_start {
	my $self = shift;
	my $enc = shift;
	my $str = shift;
	
	open LOG, '>>', $self->cretin->enclog or die $self->cretin->enclog.": $!";
	flock (LOG, LOCK_EX);
	print LOG "$str\n$enc\n", $self->serialize, "\n\n";
	flock (LOG, LOCK_UN);
	close LOG;
}

sub log_enc_finish {
	my $self = shift;
	my $enc = shift;
	my $str = shift;

	open LOG, '<', $self->cretin->enclog or return undef;
	flock (LOG, LOCK_EX);
	my @tasks = split /(?<=\n)\n+/, join ('',(<LOG>));
	flock (LOG, LOCK_UN);
	close LOG;
	
	open LOG, '>', $self->cretin->enclog or die $!;
	flock (LOG, LOCK_EX);
	
	my $found = undef;
	foreach (@tasks) {
		/^(.+)$/m; my $line1 = $1;
		if ($line1 eq $str) {
			$found = 1;
#			print "\n\nLULZ\n\n";
		} else {
			print LOG "$_\n";
#			print "\n\n$line1\nvs\n$str\n\n";
		}
	}
	
	flock (LOG, LOCK_UN);
	close LOG;
	
	return $found;
}



sub _enc_mkdir {
	my $self = shift;
	my $enc = shift;

	my $fmtdir = $self->{fmtdir} or return undef;
	
	my $dir = join ('',
				$self->cretin->{cfg}{rootdir}, '/',
				$self->cretin->{cfg}{encdir}, '/',
				$self->cretin->{encs}{$enc}{dir}, '/',
				$fmtdir,
	);
	
	my $qdir = quotemeta $dir;
	
	$self->{dir} = $dir;
	$self->{qdir} = $qdir;
	
	system ("mkdir -p $qdir");
	
	return wantarray ? ($dir, $qdir) : $dir;
}


sub _enc_mknfo {
	my $self = shift;
	my $enc = shift;
	
	my $vcmd = $self->cretin->{encs}{$enc}{cmd} . ' ' .
				$self->cretin->{encs}{$enc}{ver_flag};
	my @vary = split /\n/, `$vcmd 2>&1` or die $!;
	my $vstr = $vary[0];

	my $nfofile = join '',
			$self->cretin->{cfg}{rootdir}, '/',
			$self->{nfofile};
			
	if (-f $nfofile) {
		open OLDNFO, '<', $nfofile or die $!;
		open NEWNFO, '>', $self->{dir}.'/tracks.nfo' or die $!;
		flock (NEWNFO, LOCK_EX);
		foreach (<OLDNFO>) { print NEWNFO $_ }
		close OLDNFO;
		print NEWNFO "\nencoded with $vstr\n";
		if ($self->cretin->{encs}{$enc}{flags} ne '') {
			print NEWNFO "with flags: ", $self->cretin->{encs}{$enc}{flags}, "\n";
		}
		flock (NEWNFO, LOCK_UN);
		close NEWNFO;
	}

	return $nfofile;
}

sub _enc_exec {
	my $self = shift;
	my $enc = shift;
	
	my @args;
	foreach my $arg (@{$self->cretin->{encs}{$enc}{enc_cmd}}) {
		if ($arg eq '__OUTFILE__') {
			push @args, quotemeta join ('',
				$self->{dir}, '/', $self->{fmtfile}, '.', $self->cretin->{encs}{$enc}{ext}
			);
		}
		elsif ($arg eq '__INFILE__') {
			push @args, quotemeta join ('',
				$self->cretin->{cfg}{rootdir}, '/', $self->{path}
			);
		}
		else {
			push @args, $arg;
		}
	}
	
	my $cmd = join (' ',
		$self->cretin->{encs}{$enc}{cmd},
		$self->cretin->{encs}{$enc}{flags},
		Cretin::mkargs (
			$self->cretin->{encs}{$enc}{opt_artist}	=>	$self->artist,
			$self->cretin->{encs}{$enc}{opt_album}	=>	$self->album,
			$self->cretin->{encs}{$enc}{opt_title}	=>	$self->title,
			$self->cretin->{encs}{$enc}{opt_tnum}	=>	$self->tnum,
			$self->cretin->{encs}{$enc}{opt_year}	=>	$self->year,
			$self->cretin->{encs}{$enc}{opt_genre}	=>	$self->genre
		),
		join (' ', @args),
		'>>/dev/null',
		'2>&1'
	);
	
	print "\nProcess $$: $cmd\n";
	
	my $str = join (' / ',
		$self->cretin->{var}{hostname},
		scalar localtime,
		sprintf ('%.8x', int rand 0xFFFFFFFF)
	);
	$self->log_enc_start ($enc, $str);
	my $rv = system $cmd;
	$rv = $rv >> 8;
	$self->log_enc_finish ($enc, $str);
	
	print "\nProcess $$: Exited with value $rv",
		( $rv==0 ? " (success).\n" : " (error: $!).\n" ); 

	return 1;
}

	

	
22/7;	# close enough
