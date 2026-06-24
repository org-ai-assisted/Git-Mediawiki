#!/usr/bin/perl
# Unit test for the PUSH-side transient-retry hardening in git-remote-mediawiki
# (the mw_api_edit_retry helper + its is_transient_api_error / is_auth_transient
# classifiers, shared by page edits and media uploads).
#
# Like t9366-network-retry.t this does NOT touch a live wiki: it extracts the
# REAL subs verbatim from the shipped git-remote-mediawiki and exercises them
# with mocks, proving:
#   * the classifier correctly separates transient server errors (DBQueryError,
#     deadlock, ratelimited, maxlag, readonly, 5xx, badtoken, assert*failed)
#     from errors that must NOT be retried (permissiondenied, protectedpage,
#     sitecssprotected, a real edit conflict),
#   * a transient edit failure is retried with escalating backoff and recovers,
#   * an AUTH-class transient (badtoken) rebuilds the API handle via
#     connect_maybe(undef,...) -- the B1 fix: a warm reconnect would NOT refresh
#     a stale CSRF token, only a fresh login does,
#   * a non-transient failure returns undef immediately (so mw_push_file can
#     classify it as skip / conflict / fatal) with no retry,
#   * an unrecoverable transient exhausts the 8-attempt budget and returns undef
#     (the caller then reports non-fast-forward, never a silent success).

use strict;
use warnings;
use FindBin;
use Test::More tests => 22;

# sleep -> no-op that RECORDS its argument, so the test runs instantly yet can
# assert the backoff schedule. Installed before the helper source is compiled.
our @sleeps;
BEGIN { *CORE::GLOBAL::sleep = sub { push @sleeps, $_[0]; return; }; }

# ---- load the real subs from the shipped helper ---------------------------
my $helper = "$FindBin::Bin/../git-remote-mediawiki";
open(my $fh, '<', $helper) or die "cannot open $helper: $!";
my $src = do { local $/; <$fh> };
close($fh);

my %subs;
for my $name (qw(is_transient_api_error is_auth_transient mw_api_edit_retry)) {
	$src =~ /^sub \Q$name\E \{.*?^\}/ms
		or die "could not extract sub $name from $helper";
	$subs{$name} = $&;
}

# A controllable connect_maybe mock: records whether each (re)connect was a
# 'warm' reuse (handle passed) or a 'fresh' rebuild (undef passed -> re-login).
# On a fresh rebuild it installs the next queued handle, so the test can make
# the post-relogin edit succeed.
our @reconnects;
our @fresh_handles;
my $sandbox = join("\n",
	'package PushRetry;',
	'use strict; use warnings;',
	'our ($mediawiki, $remotename, $url);',
	'sub connect_maybe {',
	'    my ($handle, $rn, $u) = @_;',
	'    push @main::reconnects, (defined($handle) ? q{warm} : q{fresh});',
	'    return $handle if defined $handle;',
	'    return shift(@main::fresh_handles);',
	'}',
	$subs{is_transient_api_error},
	$subs{is_auth_transient},
	$subs{mw_api_edit_retry},
	'1;',
);
eval $sandbox;  ## no critic
die "sandbox compile failed: $@" if $@;

# Silence the helper's STDERR chatter.
sub quiet (&) {
	my $code = shift;
	open(my $olderr, '>&', \*STDERR) or die;
	open(STDERR, '>', '/dev/null') or die;
	my @r = $code->();
	open(STDERR, '>&', $olderr) or die;
	return wantarray ? @r : $r[0];
}

# A fake MediaWiki::API handle: ->edit() pops the next scripted outcome. An
# outcome that is a hashref with {ok} succeeds (and is returned); otherwise it
# sets {error}{code,details} and returns false, exactly like the real client.
package FakeWiki;
sub new { my ($c, @script) = @_; return bless { script => [@script], error => {} }, $c; }
sub edit {
	my $self = shift;
	my $next = shift @{$self->{script}};
	defined $next or die 'FakeWiki: ->edit called more times than scripted';
	if (ref $next eq 'HASH' && $next->{ok}) { $self->{error} = {}; return $next; }
	$self->{error} = { code => $next->{code} // 3, details => $next->{details} };
	return 0;
}
package main;

# ---- classifier truth table -----------------------------------------------
for my $c (
	['internal_api_error_DBQueryError: ...', 1, 0, 'DB deadlock -> transient, not auth'],
	['ratelimited',                          1, 0, 'rate limit -> transient'],
	['maxlag: 7 seconds',                    1, 0, 'replica lag -> transient'],
	['readonly: maintenance',                1, 0, 'read-only -> transient'],
	['HTTP 503 Service Unavailable',         1, 0, '5xx -> transient'],
	['badtoken',                             1, 1, 'stale token -> transient AND auth'],
	['assertuserfailed',                     1, 1, 'dropped login -> transient AND auth'],
	['permissiondenied',                     0, 0, 'permission -> NOT transient'],
	['protectedpage',                        0, 0, 'protected -> NOT transient'],
	['sitecssprotected',                     0, 0, 'site CSS -> NOT transient'],
	['editconflict',                         0, 0, 'real conflict -> NOT transient'],
) {
	my ($err, $want_t, $want_a, $desc) = @{$c};
	is(PushRetry::is_transient_api_error($err) ? 1 : 0, $want_t, "transient: $desc");
	is(PushRetry::is_auth_transient($err) ? 1 : 0, $want_a, "auth: $desc") if $want_a;
}

# ---- transient edit: retry with backoff, then recover ---------------------
{
	@sleeps = (); @reconnects = ();
	$PushRetry::mediawiki = FakeWiki->new(
		{ details => 'internal_api_error_DBQueryError' },
		{ details => 'internal_api_error_DBQueryError' },
		{ ok => 1, edit => { newrevid => 7 } },
	);
	my $r = quiet { PushRetry::mw_api_edit_retry({ title => 'P' }, { skip_encoding => 1 }, "pushing 'P'") };
	ok($r && $r->{ok}, 'transient DBQueryError recovered after retries');
	is_deeply(\@sleeps, [1, 2], 'escalating backoff 1s then 2s');
	is_deeply(\@reconnects, ['warm', 'warm'], 'DB transient reuses the WARM handle (no needless relogin)');
}

# ---- auth transient (badtoken): rebuild the handle, then recover ----------
{
	@sleeps = (); @reconnects = (); @fresh_handles = ();
	# After the badtoken, connect_maybe(undef,...) must hand back a NEW handle
	# whose edit succeeds (the fresh login + fresh CSRF token).
	@fresh_handles = ( FakeWiki->new({ ok => 1, edit => { newrevid => 8 } }) );
	$PushRetry::mediawiki = FakeWiki->new({ details => 'badtoken' });
	my $r = quiet { PushRetry::mw_api_edit_retry({ title => 'P' }, undef, "pushing 'P'") };
	ok($r && $r->{ok}, 'badtoken recovered after a fresh relogin');
	is_deeply(\@reconnects, ['fresh'], 'auth transient REBUILDS the handle (connect_maybe(undef)) -- the B1 fix');
}

# ---- non-transient: return undef immediately, no retry --------------------
{
	@sleeps = (); @reconnects = ();
	$PushRetry::mediawiki = FakeWiki->new({ code => 3, details => 'permissiondenied' });
	my $r = quiet { PushRetry::mw_api_edit_retry({ title => 'P' }, undef, "pushing 'P'") };
	ok(!defined $r, 'permissiondenied returns undef (caller skips/classifies) -- no retry');
	is_deeply(\@sleeps, [], 'non-transient never backs off');
}

# ---- unrecoverable transient: exhaust the budget, fail closed -------------
{
	@sleeps = (); @reconnects = ();
	$PushRetry::mediawiki = FakeWiki->new( map { { details => 'Deadlock found' } } 1 .. 9 );
	my $r = quiet { PushRetry::mw_api_edit_retry({ title => 'P' }, undef, "pushing 'P'") };
	ok(!defined $r, 'an unrecoverable transient returns undef after the budget (no silent success)');
	is(scalar(@sleeps), 8, 'exactly 8 retry attempts before giving up');
}
