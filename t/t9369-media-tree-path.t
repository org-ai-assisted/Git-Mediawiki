#!/usr/bin/perl
# Unit test for Git::Mediawiki::media_tree_path -- the on-disk path for an
# imported File: media blob. MediaWiki File: titles treat space and underscore
# as equivalent, so the stored path must use the underscore form (symmetry with
# the .mw page path, which underscores via smudge_filename's s/ /_/g). A
# space-bearing media name would otherwise diverge from the generator's
# normalized output and trip the backup-clone whitespace gate.
#
# Pure function, no live wiki.

use strict;
use warnings;
use FindBin;
use lib "$FindBin::Bin/..";
use Test::More tests => 7;
use Git::Mediawiki qw(media_tree_path);

# ---- the fix: space -> underscore (canary -- fails on pre-fix code) ---------
is(media_tree_path('Web server.png'), 'Web_server.png', 'single space -> underscore');
is(media_tree_path('A B C.png'), 'A_B_C.png', 'every space -> underscore');
is(media_tree_path('Whonix Banner 600x321.svg'), 'Whonix_Banner_600x321.svg', 'real multi-space media name');

# ---- existing behaviour preserved ------------------------------------------
is(media_tree_path('NoSpaces.png'), 'NoSpaces.png', 'already-clean name unchanged');
is(media_tree_path('Already_under.png'), 'Already_under.png', 'existing underscore preserved');
is(media_tree_path('a/b.png'), 'a_b.png', 'slash scrubbed to underscore');
is(media_tree_path("a\x{1f}b.png"), 'a_b.png', 'C0 control byte scrubbed to underscore');
