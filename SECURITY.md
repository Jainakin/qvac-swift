# Security policy

## Reporting a vulnerability

Do not open a public issue for a suspected vulnerability. Use the repository's
[private vulnerability report](https://github.com/Jainakin/qvac-swift/security/advisories/new)
to contact the maintainer.

Include the affected version or commit, platform, reproduction steps, expected
impact, and any suggested mitigation. Remove model data, prompts, tokens, local
paths, and other sensitive information from logs before attaching them.

The maintainer will acknowledge the report through the private advisory, assess
its scope, and coordinate disclosure after a fix or mitigation is available.

## Supported code

Security fixes are developed on `main` and included in the next reviewed release.
The latest published release may not contain changes that are still under review.

## Application responsibilities

QVACClient forwards model and asset locations to the local worker. Applications
that accept untrusted URLs should enforce HTTPS, host allowlists, network-range
restrictions, and expected content digests. See the
[security model](Sources/QVACClient/Documentation.docc/Security.md) for the client
and worker trust boundaries.
