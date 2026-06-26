#!/usr/bin/perl
# Unit test for empty-page handling.
#
# mediawiki_clean (git -> wiki, on push) must NOT substitute the visible
# placeholder "<!-- empty page -->" when creating an empty page: the action=edit
# API creates a genuinely empty page fine, and the placeholder LEAKS for any page
# whose content is consumed as a plain string -- e.g. MediaWiki:Aboutsite, which
# rendered "<!-- empty page -->" as the footer's About-link text.
#
# mediawiki_smudge (wiki -> git, on import) must STILL map any legacy
# EMPTY_CONTENT a previously-pushed wiki carries back to empty, so a clone of a
# wiki written by the old behaviour still round-trips to an empty file.
#
# Like t9367/t9370 this does NOT touch a live wiki: it extracts the REAL subs +
# constant verbatim from the shipped git-remote-mediawiki and exercises them.

use strict;
use warnings;
use Test::More;
use FindBin;

my $helper = "$FindBin::Bin/../git-remote-mediawiki";
open(my $fh, '<', $helper) or die "cannot open $helper: $!";
my $src = do { local $/; <$fh> };
close($fh);

my @parts;
# EMPTY is imported from Git::Mediawiki in the real helper; provide it here.
push @parts, 'use constant EMPTY => "";';
$src =~ /^use constant EMPTY_CONTENT\s*=>.*?;$/m
	or die "could not extract constant EMPTY_CONTENT from $helper";
push @parts, $&;
for my $name (qw(mediawiki_clean mediawiki_smudge)) {
	$src =~ /^sub \Q$name\E \{.*?^\}/ms
		or die "could not extract sub $name from $helper";
	push @parts, $&;
}
my $sandbox = join("\n", @parts) . "\n1;";
eval $sandbox; ## no critic
die "extract/eval failed: $@" if $@;

# push side: an empty page -- new or existing -- pushes as empty, never the marker.
is(mediawiki_clean('', 1), "\n", 'empty NEW page pushes as empty');
is(mediawiki_clean('', 0), "\n", 'empty existing page pushes as empty');
unlike(mediawiki_clean('', 1), qr/empty page/, 'no "<!-- empty page -->" leaked on create');
is(mediawiki_clean('real content', 1), "real content\n", 'real content preserved');
is(mediawiki_clean("trailing   \n\n", 1), "trailing\n", 'trailing whitespace trimmed');

# import side: a legacy placeholder maps back to empty; real content is untouched.
is(mediawiki_smudge(EMPTY_CONTENT()), "\n", 'legacy EMPTY_CONTENT imports as empty');
is(mediawiki_smudge('real'), "real\n", 'real content imported unchanged');

# round-trip: push an empty page, fetch it back -- stays empty, no placeholder.
my $pushed = mediawiki_clean('', 1);       # what we send the wiki
$pushed =~ s/\s+$//;                        # wiki right-trims trailing whitespace
is(mediawiki_smudge($pushed), "\n", 'empty page round-trips push->fetch to empty');

done_testing();
