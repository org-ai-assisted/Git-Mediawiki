package Git::Mediawiki;

require v5.26;
use strict;
use POSIX;
use Git;

use strict;
use warnings;

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
	# Defence in depth: never emit a path separator or control/NUL byte.
	$filename =~ s{[/\x00-\x1f]}{_}g;
	return substr($filename, 0, NAME_MAX-length('.mw'));
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
		if ($wiki->login($request)) {
			Git::credential(\%credential, 'approve');
			print {*STDERR} qq(Logged in mediawiki user "$credential{username}".\n);
		} else {
			print {*STDERR} qq(Failed to log in mediawiki user "$credential{username}" on ${remote_url}\n);
			print {*STDERR} '  (error ' .
				$wiki->{error}->{code} . ': ' .
				$wiki->{error}->{details} . ")\n";
			Git::credential(\%credential, 'reject');
			exit 1;
		}
	}

	return $wiki;
}

1;															# Famous last words
