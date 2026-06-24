#!/usr/bin/perl
# Unit test for resume_trim_commit_pairs, the pure helper behind resumable push.
# A push records a checkpoint (the last fully-pushed commit) on a per-remote ref;
# on the next push this helper drops the [parent, child] commit pairs already
# sent so the push continues from the checkpoint instead of re-pushing the whole
# history. Extracted verbatim from the shipped git-remote-mediawiki (the t9366
# pattern) -- no git, no wiki.

use strict;
use warnings;
use FindBin;
use Test::More tests => 8;

my $helper = "$FindBin::Bin/../git-remote-mediawiki";
open(my $fh, '<', $helper) or die "cannot open $helper: $!";
my $src = do { local $/; <$fh> };
close($fh);

$src =~ /^sub resume_trim_commit_pairs \{.*?^\}/ms
	or die "could not extract sub resume_trim_commit_pairs from $helper";
my $sandbox = "package R;\nuse strict; use warnings;\n$&\n1;";
eval $sandbox;  ## no critic
die "sandbox compile failed: $@" if $@;

# A 4-commit chain of [parent, child] pairs in push (oldest-first) order.
my @chain = (['p0','c1'], ['c1','c2'], ['c2','c3'], ['c3','c4']);

is_deeply(R::resume_trim_commit_pairs([@chain], undef), [@chain],
	'undef checkpoint: list unchanged');
is_deeply(R::resume_trim_commit_pairs([@chain], q{}), [@chain],
	'empty checkpoint: list unchanged');
is_deeply(R::resume_trim_commit_pairs([@chain], 'deadbeef'), [@chain],
	'checkpoint not on this path (stale): list unchanged');

is_deeply(R::resume_trim_commit_pairs([@chain], 'c2'),
	[['c2','c3'], ['c3','c4']],
	'mid-chain checkpoint: drops everything up to AND including it');
is_deeply(R::resume_trim_commit_pairs([@chain], 'c1'),
	[['c1','c2'], ['c2','c3'], ['c3','c4']],
	'first-commit checkpoint: drops only the first pair');
is_deeply(R::resume_trim_commit_pairs([@chain], 'c4'),
	[],
	'last-commit checkpoint: everything already pushed -> empty');

# Matches on the CHILD (the pushed commit), never the parent boundary.
is_deeply(R::resume_trim_commit_pairs([@chain], 'p0'), [@chain],
	'a parent-only sha (boundary) is not a checkpoint match: unchanged');

# Empty input is safe.
is_deeply(R::resume_trim_commit_pairs([], 'c2'), [],
	'empty commit list: unchanged');
