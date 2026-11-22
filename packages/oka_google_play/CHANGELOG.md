# Changelog

All notable changes to `oka_google_play` are documented here. The release
train prepends sections per version — headings start with the exact
version.

## 0.12.0

- New package (ADR-0056 store/platform line): the Google Play STORE
  package — `storeKeyGooglePlay` plus the Play publish channel
  (`PlayPublishTarget`, Play Publisher API Edits-flow upload tail,
  dry-run plans, service-account credentials by path). Succeeds the
  retired `oka_play` package; the store key identity joins the channel in
  one store package.
