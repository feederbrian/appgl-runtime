# Security Policy

## Reporting a vulnerability

**Please do not open a public issue for a security finding.**

Use GitHub's [private vulnerability reporting](https://docs.github.com/en/code-security/security-advisories/guidance-on-reporting-and-writing-information-about-vulnerabilities/privately-reporting-a-security-vulnerability)
on this repository. That keeps the report private until a fix exists.

## What is in scope

AppGL translates untrusted shader and API input into Metal. The findings most worth reporting are
those where **input controls behaviour beyond a clean error**:

- shader source or SPIR-V that causes out-of-bounds access, use-after-free, or type confusion
- API sequences that corrupt internal state in a way an application can steer
- anything where a crash appears controllable rather than incidental

Ordinary crashes, conformance failures, and unimplemented features are **not** security issues —
please hold those until the project accepts general issues.

## What to expect

**This is pre-release software with no production support and no response-time commitment.** Reports
will be read, but there is no advisory process, no CVE assignment, and no patch schedule yet. This
document will be replaced with real commitments when the project is ready for use.

## Supported versions

None. No release has been made, and no version is supported.
