# Contributing to AbelNotes

Contributions are welcome: bug fixes, platform polish, translations, tests
against real WebDAV servers (Seafile, Synology, generic WebDAV), import edge
cases.

## Before your first pull request

AbelNotes is free software under the AGPL-3.0 and is also published in app
stores. To keep that possible, every contributor signs the
[Contributor License Agreement](CLA.md) once. You keep the copyright in your
work; you give the project a licence to use and distribute it, app stores
included. A bot asks you to sign on your first pull request; it takes one
comment.

## Pull requests

- One topic per pull request; describe what changed and how you tested it.
- Commit subjects follow `type(scope): summary`, for example
  `fix(sync): retry a failed upload` or `build(flatpak): bump the runtime`.
- Sign off your commits (`git commit -s`), certifying the
  [Developer Certificate of Origin](https://developercertificate.org/).
- Run `flutter analyze` and `flutter test` before opening the pull request.
- Every user-facing string goes through the translation files in `lib/l10n/`;
  never hard-code text in one language.
- Keep personal data out of commits: no local paths, email addresses or
  machine names, in code, logs or committed binaries.

## Reporting bugs and security issues

Open an issue for bugs and feature requests. For security problems, follow
[SECURITY.md](SECURITY.md) instead of opening a public issue.
