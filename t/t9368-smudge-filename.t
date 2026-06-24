#!/usr/bin/perl
# Unit test for Git::Mediawiki::smudge_filename, covering two distinct defects
# in the SAME function:
#   * security finding 01 -- a crafted page title must NOT be able to decode
#     _%_<hex> back into a path separator / dot segment ('/','.') and so inject
#     a '../' path-traversal entry into the fast-import stream. Only the exact
#     characters clean_filename() encodes ([ ] { } |) may be decoded.
#   * non-security N2 -- title truncation must respect the NAME_MAX BYTE budget
#     even though MediaWiki::API hands us DECODED CHARACTER strings: truncating
#     on the character string both under-truncates multibyte titles (length()
#     counts characters, not bytes) and, with a byte-oriented strip regex, can
#     delete a valid trailing character whose code point lands in 0xC2-0xF4.
#     The fix encodes to UTF-8, truncates/strips in the byte domain, decodes
#     back -- so this test feeds CHARACTER strings, the real input type.
#
# Pure function, no live wiki.

use strict;
use warnings;
use FindBin;
use lib "$FindBin::Bin/..";
use Test::More tests => 14;
use Encode qw(encode_utf8 decode_utf8);
use Git::Mediawiki qw(clean_filename smudge_filename);

use constant NAME_MAX => 255;          # Linux filesystem byte limit
use constant BUDGET   => NAME_MAX - length('.mw');

sub blen { return length(encode_utf8($_[0])); }   # byte length of a char string

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

# ---- N2: byte-budget truncation on DECODED CHARACTER strings ---------------
{
	# Byte length exceeds the budget while the CHARACTER count does not -- the
	# case the character-domain code missed entirely (would return 400 bytes).
	my $title = "\x{00E9}" x 200;                  # 200 'é' chars = 400 bytes
	my $out   = smudge_filename($title);
	cmp_ok(blen($out), '<=', BUDGET, 'multibyte title truncated to the BYTE budget, not the char count');
	is(decode_utf8(encode_utf8($out)), $out, 'result is valid UTF-8');
	like($out, qr/\A\x{00E9}+\z/, 'result is whole é characters -- no codepoint-domain corruption');
}
{
	# A 3-byte char split by the byte cut is dropped cleanly (no mojibake).
	my $title = ('a' x (BUDGET - 1)) . "\x{2603}";  # (BUDGET-1) ascii + snowman
	my $out   = smudge_filename($title);
	cmp_ok(blen($out), '<=', BUDGET, 'straddling multibyte char: within byte budget');
	unlike($out, qr/\x{2603}/, 'the split snowman is dropped, not left half-encoded');
}
{
	# Under budget, no space / forbidden chars: returned unchanged (no needless
	# truncation, strip, or codepoint-domain corruption). (A space would map to
	# '_' by design, so it is deliberately excluded here.)
	my $title = "Caf\x{00E9}\x{2603}eta";
	is(smudge_filename($title), $title, 'short char-string title is unchanged');
}
