#!/usr/bin/perl

use ExtUtils::MakeMaker;


print "Deleting Mac OS resource fork droppings.\n";

chomp (my @files = `find .`);
my @rmfiles = grep { m|[/^]\._| } @files;
for (@rmfiles) { print "  $_\n"; system 'rm ' . quotemeta }



print "Building www/docs.html.\n";

my $html = `pod2html lib/Cretin.pm`;
system ("rm pod2*.tmp");
$html =~ s|.*<body[^>]*>(.+)</body.*|$1|s;
my $docs;
open DOCS, '<', 'www/docs.html' or die $!;
while ($_ = <DOCS>) {
	$docs .= $_;
	last if /<!-- begin man page -->/;
}
$docs .= "\n$html\n";
while ($_ = <DOCS>) {
	if (/<!-- end man page -->/) {
		$docs .= $_;
		last;
	}
}
for (<DOCS>) { $docs .= $_ }
close DOCS;
open DOCS, '>', 'www/docs.html' or die $!;
print DOCS $docs;
close DOCS;




WriteMakefile (
	NAME			=>	'Cretin',
	VERSION_FROM	=>	'lib/Cretin.pm',
	EXE_FILES		=>	['bin/cretin'],
	MAN3PODS		=>	{'lib/Cretin.pm' => 'blib/man3/cretin.3'},
	PREREQ_PM		=>	{ 'CDDB' => 0 },
);
