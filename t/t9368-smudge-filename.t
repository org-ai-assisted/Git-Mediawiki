#!/usr/bin/perl
# Unit test for Git::Mediawiki::smudge_filename, covering two distinct defects
# in the SAME function:
#   * security finding 01 -- a crafted page title must NOT be able to decode
#     _%_<hex> back into a path separator / dot segment ('/','.') and so inject
#     a '../' path-traversal entry into the fast-import stream. Only the exact
#     characters clean_filename() encodes ([ ] { } |) may be decoded.
#   * non-security N2 -- a near-NAME_MAX title truncated by BYTES must not be
#     cut through the middle of a multi-byte UTF-8 character (which yields an
#     invalid filename); a trailing INCOMPLETE sequence is dropped, a COMPLETE
#     trailing character is preserved.
#
# Pure function, no live wiki.

use strict;
use warnings;
use FindBin;
use lib "$FindBin::Bin/..";
use Test::More tests => 11;
use Git::Mediawiki qw(clean_filename smudge_filename);

use constant NAME_MAX => 255;          # Linux filesystem byte limit
use constant BUDGET   => NAME_MAX - length('.mw');

# ---- security finding 01: no path-separator / dot re-injection ------------
unlike(smudge_filename('a_%_2fb'), qr{/}, 'does NOT decode _%_2f into a slash');
unlike(smudge_filename('a_%_2eb'), qr{[.]}, 'does NOT decode _%_2e into a dot');
unlike(smudge_filename('_%_2e_%_2e_%_2fetc'), qr{[.][.]/}, 'no ../ traversal from crafted title');
# the legitimately-encoded forbidden characters ARE decoded back
is(smudge_filename('a_%_5bb_%_5dc'), 'a[b]c', 'decodes _%_5b/_%_5d back to [ ]');
is(smudge_filename('x_%_7cy'), 'x|y', 'decodes _%_7c back to a pipe');

# ---- clean -> smudge round-trip preserves the forbidden set ----------------
for my $name ('Foo[bar]', 'a|b', '{tpl}') {
	is(smudge_filename(clean_filename($name)), $name, "round-trip preserves '$name'");
}

# ---- N2: UTF-8-safe truncation at the byte budget --------------------------
{
	my $snowman = "\xE2\x98\x83";                 # U+2603, 3 bytes
	my $title   = ('a' x (BUDGET - 1)) . $snowman; # BUDGET+2 bytes, cut splits the char
	my $out     = smudge_filename($title);
	cmp_ok(length($out), '<=', BUDGET, 'truncated within the byte budget');
	my $dangling = ($out =~ /(?:[\xC2-\xDF]|[\xE0-\xEF][\x80-\xBF]?|[\xF0-\xF4][\x80-\xBF]{0,2})\z/);
	ok(!$dangling, 'no dangling partial UTF-8 sequence after truncation');
}
{
	# A complete trailing multi-byte character that already fits is untouched.
	my $short = "Foo\xE2\x98\x83";
	is(smudge_filename($short), $short, 'complete trailing UTF-8 char is preserved');
}
