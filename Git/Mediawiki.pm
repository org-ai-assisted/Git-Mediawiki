package Git::Mediawiki;

require v5.26;
use strict;
use POSIX;
use Git;

use strict;
use warnings;
use Encode qw(encode_utf8 decode_utf8);

BEGIN {

	our ($VERSION, @ISA, @EXPORT, @EXPORT_OK);

	# Totally unstable API.
	$VERSION = '0.01';

	require Exporter;

	@ISA = qw(Exporter);

	# Methods which can be called as standalone functions as well:
	@EXPORT_OK = qw(clean_filename smudge_filename connect_maybe
									EMPTY HTTP_CODE_OK HTTP_CODE_PAGE_NOT_FOUND);
}

# Mediawiki filenames can contain forward slashes. This variable decides by which pattern they should be replaced
use constant SLASH_REPLACEMENT => '%2F';

# Used to test for empty strings
use constant EMPTY => q{};

# HTTP codes
use constant HTTP_CODE_OK => 200;
use constant HTTP_CODE_PAGE_NOT_FOUND => 404;

sub clean_filename {
	my $filename = shift;
	$filename =~ s{@{[SLASH_REPLACEMENT]}}{/}g;
	# [, ], |, {, and } are forbidden by MediaWiki, even URL-encoded.
	# Do a variant of URL-encoding, i.e. looks like URL-encoding,
	# but with _ added to prevent MediaWiki from thinking this is
	# an actual special character.
	$filename =~ s/[\[\]\{\}\|]/sprintf("_%%_%x", ord($&))/ge;
	# If we use the uri escape before
	# we should unescape here, before anything

	return $filename;
}

sub smudge_filename {
	my $filename = shift;
	$filename =~ s{/}{@{[SLASH_REPLACEMENT]}}g;
	$filename =~ s/ /_/g;
	# Decode forbidden characters encoded in clean_filename.
	# SECURITY: only decode the exact characters clean_filename() encodes
	# ([ ] { } |). An unrestricted hex decode let a crafted page title
	# reintroduce path separators / dot segments (e.g. _%_2f -> '/',
	# _%_2e -> '.') *after* the '/' -> '%2F' step above, yielding '../'
	# path-traversal entries in the fast-import stream.
	$filename =~ s/_%_([0-9a-fA-F][0-9a-fA-F])/
		my $c = hex($1);
		($c == 0x5b || $c == 0x5d || $c == 0x7b || $c == 0x7d || $c == 0x7c)
			? chr($c) : "_%_$1"/ge;
	# Defence in depth: never emit a path separator or control byte -- the C0
	# range \x00-\x1f AND DEL \x7f.
	$filename =~ s{[/\x00-\x1f\x7f]}{_}g;
	# Keep room for the '.mw' suffix appended by the caller. NAME_MAX is a BYTE
	# budget, but $filename is a decoded CHARACTER string (MediaWiki::API
	# JSON-decodes API responses), so measure and cut in the BYTE domain: encode
	# to UTF-8, truncate at the budget, drop any trailing INCOMPLETE multi-byte
	# sequence the cut left (complete characters untouched), then decode back.
	# Truncating the character string instead would both miss over-budget
	# multi-byte titles (length() counts characters, not bytes) and corrupt a
	# valid trailing character whose code point lands in 0xC2-0xF4. (Local fork
	# change -- robustness, non-security; cf. security finding 01.)
	my $max = NAME_MAX - length('.mw');
	my $bytes = encode_utf8($filename);
	if (length($bytes) > $max) {
		$bytes = substr($bytes, 0, $max);
		$bytes =~ s/
			(?: [\xC2-\xDF]                  # 2-byte lead, 0 continuations
			  | [\xE0-\xEF] [\x80-\xBF]?     # 3-byte lead, <2 continuations
			  | [\xF0-\xF4] [\x80-\xBF]{0,2} # 4-byte lead, <3 continuations
			) \z//x;
		$filename = decode_utf8($bytes);
	}
	return $filename;
}

sub connect_maybe {
	my $wiki = shift;
	if ($wiki) {
		return $wiki;
	}

	my $remote_name = shift;
	my $remote_url = shift;
	my ($wiki_login, $wiki_password, $wiki_domain);

	$wiki_login = Git::config("remote.${remote_name}.mwLogin");
	$wiki_password = Git::config("remote.${remote_name}.mwPassword");
	$wiki_domain = Git::config("remote.${remote_name}.mwDomain");

	$wiki = MediaWiki::API->new;

	# Network-retry robustness for API calls.
	#
	# MediaWiki::API wraps every api()/list()/edit() call in its own retry +
	# maxlag loop, but ships those OFF by default (retries=0, max_lag=undef): a
	# single transient HTTP error (timeout, reset, 5xx) therefore aborts the
	# whole fetch. Enable them, driven by remote.<remote>.maxRetries (retries
	# after the first attempt; default 3, 0 disables). retry_delay seeds an
	# escalating wait (the library also honours the server's reported lag via
	# maxlag), so transient failures back off instead of killing the fetch.
	# Permanent failures (auth/4xx, semantic API errors) are not retried by the
	# library and still surface immediately.
	my $max_retries = Git::config("remote.${remote_name}.maxRetries");
	if (!defined($max_retries) || $max_retries eq '') {
		$max_retries = 3;
	}
	$max_retries = int($max_retries);
	$max_retries = 0 if $max_retries < 0;
	$wiki->{config}->{retries} = $max_retries;
	$wiki->{config}->{retry_delay} = 2;
	# Ask the server to defer requests when its replication lag is high, and
	# retry rather than error out when it is. 5s is the value the MediaWiki
	# maxlag manual recommends.
	$wiki->{config}->{max_lag} = 5;
	$wiki->{config}->{max_lag_delay} = 5;
	# Floor maxlag retries at 4 (replica lag is common and deserves more
	# patience than a generic transient) -- but honour an explicit 0: when the
	# user disables retries (maxRetries=0) do not silently retry maxlag either.
	$wiki->{config}->{max_lag_retries} =
		$max_retries == 0 ? 0 : ($max_retries > 4 ? $max_retries : 4);

	$wiki->{ua}->agent("git-mediawiki/$Git::Mediawiki::VERSION " . $wiki->{ua}->agent());
	$wiki->{ua}->conn_cache({total_capacity => undef});
	# SECURITY: restrict the user agent to HTTP(S). Media downloads fetch a
	# URL supplied by the wiki API (imageinfo.url) with no scheme check, so
	# a malicious/compromised server could return file://, ftp://, etc. and
	# trigger local-file read / SSRF. LWP only dispatches allowed schemes.
	$wiki->{ua}->protocols_allowed([ 'http', 'https' ]);

	$wiki->{config}->{api_url} = "${remote_url}/api.php";
	if ($wiki_login) {
		my %credential = (
			'url' => $remote_url,
			'username' => $wiki_login,
			'password' => $wiki_password
		);
		Git::credential(\%credential);
		my $request = {lgname => $credential{username},
										lgpassword => $credential{password},
										lgdomain => $wiki_domain};
		# Retry a transient login failure with backoff before the fatal exit. A
		# long bulk push can outlive its server session; the re-login that then
		# follows (connect_maybe(undef,...) on a badtoken) can race a momentary
		# server error / login throttle -- and since the credentials are already
		# known-good at that point, a failure here is almost always transient.
		# Without this, the single-attempt login exit 1'd and killed the whole
		# push (the bug behind a mid-push "Login Failure" abort). Bounded by
		# maxRetries; a genuinely rejected credential still fails after the
		# attempts. (Local fork change.)
		my $login_attempt = 0;
		my $logged_in = 0;
		while (1) {
			if ($wiki->login($request)) {
				Git::credential(\%credential, 'approve');
				print {*STDERR} qq(Logged in mediawiki user "$credential{username}".\n);
				$logged_in = 1;
				last;
			}
			last if $login_attempt >= $max_retries;
			$login_attempt++;
			print {*STDERR} qq(Transient login failure for "$credential{username}" )
				. qq{(attempt ${login_attempt}): }
				. ($wiki->{error}->{code} // q{}) . q{: }
				. ($wiki->{error}->{details} // q{}) . "; retrying...\n";
			sleep($login_attempt * 2);
		}
		if (!$logged_in) {
			print {*STDERR} qq(Failed to log in mediawiki user "$credential{username}" on ${remote_url}\n);
			print {*STDERR} '  (error ' .
				($wiki->{error}->{code} // q{}) . ': ' .
				($wiki->{error}->{details} // q{}) . ")\n";
			Git::credential(\%credential, 'reject');
			exit 1;
		}
	}

	return $wiki;
}

1;															# Famous last words
