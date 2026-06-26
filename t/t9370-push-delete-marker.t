#!/usr/bin/perl
# Unit test for the content-model-aware deletion marker on the PUSH side
# (deleted_content_for_title) and its IMPORT-side recogniser (is_deleted_marker).
#
# A deletion of a css/javascript content-model page must NOT write the wikitext
# marker "[[Category:Deleted]]" -- stored into such a page it is served literally
# (dead CSS / a JS parse error) and silently breaks the wiki's combined site
# assets. So a css/js deletion writes a marker valid for the model. The catch:
# the import path turns a deletion marker back into a fast-import `D` (real
# deletion), so it MUST recognise the css/js markers too -- otherwise a later
# fetch re-imports the marker as ordinary page content and resurrects the page.
#
# Like t9367 this does NOT touch a live wiki: it extracts the REAL subs +
# constants verbatim from the shipped git-remote-mediawiki and exercises them.

use strict;
use warnings;
use Test::More;
use FindBin;

my $helper = "$FindBin::Bin/../git-remote-mediawiki";
open(my $fh, '<', $helper) or die "cannot open $helper: $!";
my $src = do { local $/; <$fh> };
close($fh);

my @parts;
for my $name (qw(DELETED_CONTENT DELETED_CONTENT_CSS DELETED_CONTENT_JS)) {
	$src =~ /^use constant \Q$name\E\s*=>.*?;$/m
		or die "could not extract constant $name from $helper";
	push @parts, $&;
}
for my $name (qw(deleted_content_for_title is_deleted_marker)) {
	$src =~ /^sub \Q$name\E \{.*?^\}/ms
		or die "could not extract sub $name from $helper";
	push @parts, $&;
}
my $sandbox = join("\n", @parts) . "\n1;";
eval $sandbox; ## no critic
die "extract/eval failed: $@" if $@;

# deleted_content_for_title picks a marker by content model (title suffix).
is(deleted_content_for_title('MediaWiki:Common.css'), DELETED_CONTENT_CSS(), 'css page -> css marker');
is(deleted_content_for_title('MediaWiki:Vector.css'), DELETED_CONTENT_CSS(), 'another css page -> css marker');
is(deleted_content_for_title('MediaWiki:Common.js'),  DELETED_CONTENT_JS(),  'js page -> js marker');
is(deleted_content_for_title('User:Foo/common.js'),   DELETED_CONTENT_JS(),  'user js -> js marker');
is(deleted_content_for_title('Donate'),               DELETED_CONTENT(),     'wikitext page -> wikitext marker');
is(deleted_content_for_title('File:Logo.png'),        DELETED_CONTENT(),     'file page -> wikitext marker');

# the css/js markers must be valid for their model -- no wikitext brackets.
unlike(DELETED_CONTENT_CSS(), qr/\[\[/, 'css marker carries no wikitext');
unlike(DELETED_CONTENT_JS(),  qr/\[\[/, 'js marker carries no wikitext');

# is_deleted_marker recognises every marker, but not ordinary content.
ok(is_deleted_marker(DELETED_CONTENT()),     'wikitext marker recognised');
ok(is_deleted_marker(DELETED_CONTENT_CSS()), 'css marker recognised');
ok(is_deleted_marker(DELETED_CONTENT_JS()),  'js marker recognised');
ok(!is_deleted_marker("/* real css rule */\n"), 'real css is not a deletion');
ok(!is_deleted_marker("// real js code\n"),     'real js is not a deletion');
ok(!is_deleted_marker("ordinary wikitext\n"),   'real wikitext is not a deletion');

# THE invariant: every marker the push writes, the import recognises as a
# deletion -- so a deletion round-trips instead of resurrecting on fetch.
for my $title ('X.css', 'X.js', 'X', 'MediaWiki:Common.css', 'MediaWiki:Common.js') {
	ok(is_deleted_marker(deleted_content_for_title($title)),
		"round-trip: deletion of '$title' is recognised on import");
}

done_testing();
