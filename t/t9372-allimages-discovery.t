#!/usr/bin/perl
# Unit test for list=allimages discovery of description-less uploaded files.
#
# An uploaded file can exist with NO File: description page. list=allpages
# (description pages only) misses it, and prop=links|images finds it but
# get_mw_first_pages drops the "missing" negative-pageid result -- so its binary
# was never fetched and the exported wiki linked a media file that did not exist
# (e.g. kicksecure's Logo-usb-500x500.png referenced from [[Download]]).
#
# get_all_images enumerates uploaded files via list=allimages and inserts a
# synthetic File: entry keyed by title straight into %pages, so the media
# backfill fetches the binary. This proves:
#   * a description-less upload is added to %pages,
#   * a File: page already discovered (with a pageid) is NOT clobbered (//= dedup),
#   * a row carrying only 'name' still yields a "File:<name>" title,
#   * list=allimages returning undef warns and does not crash the fetch,
#   * file_namespace_in_scope gates the whole thing on the File namespace,
#   * fetch_mw_revisions_for_page skips a pageid-less entry WITHOUT an API call
#     (the by_page strategy would otherwise send pageids=undef).
#
# Like t9366/t9371 this does NOT touch a live wiki: it extracts the REAL subs
# verbatim from the shipped git-remote-mediawiki and exercises them with mocks.

use strict;
use warnings;
use Test::More tests => 11;
use FindBin;

my $helper = "$FindBin::Bin/../git-remote-mediawiki";
open(my $fh, '<', $helper) or die "cannot open $helper: $!";
my $src = do { local $/; <$fh> };
close($fh);

my %subs;
for my $name (qw(get_all_images file_namespace_in_scope fetch_mw_revisions_for_page)) {
	$src =~ /^sub \Q$name\E \{.*?^\}/ms
		or die "could not extract sub $name from $helper";
	$subs{$name} = $&;
}

# Wiring guard: get_mw_pages must actually call get_all_images.
$src =~ /^sub get_mw_pages \{.*?^\}/ms
	or die "could not extract sub get_mw_pages from $helper";
like($&, qr/get_all_images/, 'get_mw_pages wires in list=allimages discovery');

my $sandbox = join("\n",
	'package AllImagesTest;',
	'use strict; use warnings;',
	'our $mediawiki;',
	'our @tracked_namespaces;',
	'our $shallow_import;',
	# stub the namespace resolver used by file_namespace_in_scope
	q{sub get_mw_namespace_id { return { 'File' => 6, 'Template' => 10, 'User' => 2, 'Help' => 12 }->{$_[0]}; }},
	$subs{get_all_images},
	$subs{file_namespace_in_scope},
	$subs{fetch_mw_revisions_for_page},
	'1;',
);
eval $sandbox; ## no critic
die "sandbox compile failed: $@" if $@;

# Silence the helper's STDERR chatter during the test.
sub quiet (&) {
	my $code = shift;
	open(my $olderr, '>&', \*STDERR) or die;
	open(STDERR, '>', '/dev/null') or die;
	my @r = $code->();
	open(STDERR, '>&', $olderr) or die;
	return wantarray ? @r : $r[0];
}

# A fake MediaWiki::API: ->list returns a canned result; ->api must never be hit.
package FakeMW;
sub new { my ($c, %a) = @_; return bless { %a }, $c; }
sub list { my ($self, $q) = @_; $self->{list_query} = $q; return $self->{list_result}; }
sub api { die "fetch_mw_revisions_for_page must NOT call the API for a pageid-less entry\n"; }
package main;

# ---- get_all_images: discovery + dedup ------------------------------------
{
	$AllImagesTest::mediawiki = FakeMW->new(list_result => [
		{ title => 'File:Logo-usb-500x500.png', name => 'Logo-usb-500x500.png' },
		{ title => 'File:Has-Description.png',  name => 'Has-Description.png' },
		{ name => 'Only-Name.png' },   # no title field -> build "File:<name>"
	]);
	# A description page already discovered carries a pageid; it must survive.
	my %pages = ('File:Has-Description.png' => { title => 'File:Has-Description.png', pageid => 42 });

	quiet { AllImagesTest::get_all_images(\%pages); };

	ok(exists $pages{'File:Logo-usb-500x500.png'}, 'description-less upload added to %pages');
	is($pages{'File:Logo-usb-500x500.png'}{title}, 'File:Logo-usb-500x500.png',
		'synthetic entry keyed and titled correctly');
	is($pages{'File:Has-Description.png'}{pageid}, 42,
		'already-discovered File: page NOT clobbered (//= dedup)');
	ok(exists $pages{'File:Only-Name.png'}, 'row with only name yields File:<name> entry');
	is($AllImagesTest::mediawiki->{list_query}{list}, 'allimages',
		'discovery uses list=allimages');
}

# ---- get_all_images: undef result warns, does not crash -------------------
{
	$AllImagesTest::mediawiki = FakeMW->new(list_result => undef);
	my %pages = ('File:Keep.png' => { title => 'File:Keep.png' });
	my $ok = eval { quiet { AllImagesTest::get_all_images(\%pages); }; 1; };
	ok($ok, 'undef allimages result does not die');
	is_deeply([sort keys %pages], ['File:Keep.png'], 'undef result leaves %pages untouched');
}

# ---- file_namespace_in_scope ----------------------------------------------
{
	local @AllImagesTest::tracked_namespaces = ('(Main)', 'Template', 'File', 'Help');
	ok(AllImagesTest::file_namespace_in_scope(), 'File tracked => in scope');

	local @AllImagesTest::tracked_namespaces = ('(Main)', 'Template', 'Help');
	ok(!AllImagesTest::file_namespace_in_scope(), 'File not tracked => out of scope');
}

# ---- fetch_mw_revisions_for_page: pageid-less entry skips the API ----------
{
	$AllImagesTest::mediawiki = FakeMW->new();   # ->api dies if reached
	my @revs = quiet {
		AllImagesTest::fetch_mw_revisions_for_page(
			{ title => 'File:Logo-usb-500x500.png' }, undef, 1);
	};
	is_deeply(\@revs, [], 'undef pageid returns no revisions without an API call');
}
