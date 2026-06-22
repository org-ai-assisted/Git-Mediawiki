#!/usr/bin/perl
# Unit test for the network-retry robustness added to git-remote-mediawiki.
#
# This test does NOT touch a live wiki. It loads the *real* retry helpers
# (mw_retry, is_transient_http_code) out of the git-remote-mediawiki script and
# exercises them directly with mocks, proving:
#   * a transient failure (HTTP 500 / timeout / 429) is RETRIED and then
#     RECOVERS instead of killing the fetch,
#   * a permanent failure (HTTP 404 / 403) is NOT retried,
#   * backoff is exponential and the retry budget (maxRetries) is honoured,
#   * after the retry budget is exhausted the loop FAILS LOUD (returns the last
#     failing result so the caller can die) rather than silently succeeding.
#
# The helper subs are pure (they depend only on a few constants and the
# package-scoped $max_retries), so we extract their source verbatim from the
# shipped script and eval it here. This guarantees we test the actual code that
# ships, with no duplicated logic.

use strict;
use warnings;
use FindBin;
use Test::More tests => 15;

# Make sleep a no-op that RECORDS its argument, so the test runs instantly yet
# can assert the exponential backoff schedule. Must be installed before the
# helper source (which calls sleep) is compiled.
our @sleeps;
BEGIN { *CORE::GLOBAL::sleep = sub { push @sleeps, $_[0]; return; }; }

# ---- load the real subs from the shipped helper ---------------------------
my $helper = "$FindBin::Bin/../git-remote-mediawiki";
open(my $fh, '<', $helper) or die "cannot open $helper: $!";
my $src = do { local $/; <$fh> };
close($fh);

# The constants the helpers reference.
my %const = (
	RETRY_BACKOFF_BASE        => 1,
	RETRY_BACKOFF_MAX         => 30,
	HTTP_CODE_REQUEST_TIMEOUT => 408,
	HTTP_CODE_TOO_MANY_REQUESTS => 429,
);

# Pull out the two sub definitions verbatim.
my %subs;
for my $name (qw(is_transient_http_code mw_retry)) {
	$src =~ /^sub \Q$name\E \{.*?^\}/ms
		or die "could not extract sub $name from $helper";
	$subs{$name} = $&;
}

# Build a sandbox package that defines the constants, a controllable
# $max_retries, and the two real subs. sleep is already overridden globally
# above to record backoff instead of waiting.
my $sandbox = join("\n",
	'package RetryTest;',
	'use strict; use warnings;',
	# constants
	(map { "use constant $_ => $const{$_};" } sort keys %const),
	# package-scoped retry budget, set per scenario by set_max_retries()
	'our $max_retries;',
	# the real subs, verbatim from the shipped helper
	$subs{is_transient_http_code},
	$subs{mw_retry},
	'1;',
);

eval $sandbox;  ## no critic
die "sandbox compile failed: $@" if $@;

# Bind $max_retries inside the sandbox package for each scenario.
sub set_max_retries {
	no strict 'refs';
	${'RetryTest::max_retries'} = shift;
	return;
}

# Silence the helper's progress chatter on STDERR during the test.
sub quiet (&) {
	my $code = shift;
	open(my $olderr, '>&', \*STDERR) or die;
	open(STDERR, '>', '/dev/null') or die;
	my @r = $code->();
	open(STDERR, '>&', $olderr) or die;
	return wantarray ? @r : $r[0];
}

# A fake HTTP response object exposing ->code like LWP::UA's response.
package FakeResp;
sub new { my ($c, $code) = @_; return bless { code => $code }, $c; }
sub code { return $_[0]->{code}; }
package main;

# ---- is_transient_http_code classification --------------------------------
ok( RetryTest::is_transient_http_code(500), '500 is transient');
ok( RetryTest::is_transient_http_code(503), '503 is transient');
ok( RetryTest::is_transient_http_code(408), '408 (timeout) is transient');
ok( RetryTest::is_transient_http_code(429), '429 (rate limit) is transient');
ok( RetryTest::is_transient_http_code(0),   '0 (no response object) is transient (defensive)');
ok(!RetryTest::is_transient_http_code(404), '404 is NOT transient');
ok(!RetryTest::is_transient_http_code(403), '403 is NOT transient');
ok(!RetryTest::is_transient_http_code(200), '200 is NOT transient');

# ---- transient failure: retry then recover --------------------------------
{
	set_max_retries(3);
	@sleeps = ();
	# Fail twice with 503, then succeed with 200.
	my @codes = (503, 503, 200);
	my $calls = 0;
	my $resp = quiet {
		RetryTest::mw_retry(
			'fetch thing',
			sub { my $r = shift; return RetryTest::is_transient_http_code($r->code); },
			sub { $calls++; return FakeResp->new(shift @codes); },
		);
	};
	is($calls, 3, 'transient: attempted 3 times (2 failures + 1 success)');
	is($resp->code, 200, 'transient: recovered with HTTP 200');
	is_deeply(\@sleeps, [1, 2], 'transient: exponential backoff 1s then 2s');
}

# ---- permanent failure: no retry ------------------------------------------
{
	set_max_retries(3);
	@sleeps = ();
	my $calls = 0;
	my $resp = quiet {
		RetryTest::mw_retry(
			'fetch missing',
			sub { my $r = shift; return RetryTest::is_transient_http_code($r->code); },
			sub { $calls++; return FakeResp->new(404); },
		);
	};
	is($calls, 1, 'permanent 404: attempted exactly once (no retry)');
	is_deeply(\@sleeps, [], 'permanent 404: never backed off');
}

# ---- transient that never recovers: exhaust budget, fail loud -------------
{
	set_max_retries(2);
	@sleeps = ();
	my $calls = 0;
	my $resp = quiet {
		RetryTest::mw_retry(
			'fetch always-down',
			sub { my $r = shift; return RetryTest::is_transient_http_code($r->code); },
			sub { $calls++; return FakeResp->new(500); },
		);
	};
	# maxRetries=2 => 1 initial + 2 retries = 3 attempts, then give up.
	is($calls, 3, 'exhausted: 1 initial + 2 retries = 3 attempts');
	is($resp->code, 500,
		'exhausted: returns the last FAILING result (caller fails loud, never silently skips)');
}
