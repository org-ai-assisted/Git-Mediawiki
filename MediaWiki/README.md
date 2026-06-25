# Vendored MediaWiki::API (patched)

`API.pm` here is a **vendored, patched copy** of the CPAN module `MediaWiki::API`
(as shipped in Debian `libmediawiki-api-perl` 0.52-2). `git-remote-mediawiki` does
`use lib (split(/:/, $ENV{GITPERLLIB}))` and `git-mediawiki-patched` exports
`GITPERLLIB=<this fork>`, so this copy precedes the system module on `@INC` — the
patched client is used with **no dependency on the Debian package and no system
file modification**.

## Why vendored here (not MWCD)

MWCD vendors the wiki **server** (MediaWiki core + extensions). `MediaWiki::API`
is the **client** library git-mediawiki uses to talk to a wiki's API — the server
never loads it. It belongs with the client (this fork), alongside the already-
vendored `Git/Mediawiki.pm`.

## The patch

Non-ASCII POST fix: `MediaWiki::API::_encode_hashref_utf8` leaves params as
wide-char / utf8-flagged strings (correct for the URI/GET path), but on the default
POST path modern libwww-perl rejects a wide string with
`HTTP::Message content must be bytes`. Any page text / title / summary carrying a
non-ASCII character aborted the whole push. The fix encodes each scalar param to
UTF-8 bytes immediately before `->post`.

## Provenance / upstream

The base import, the fix as an isolated commit, and a regression test live in
`~/private-sources/mediawiki-api-perl` (the upstream-PR artifact, target
<https://metacpan.org/release/MediaWiki-API>). Regenerate this vendored copy with:

    cp ~/private-sources/mediawiki-api-perl/lib/MediaWiki/API.pm ./API.pm
