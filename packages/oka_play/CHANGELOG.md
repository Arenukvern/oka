## 0.1.6

- Initial release (ADR-0014 P1): `PlayPublishTarget` (`PublishTarget`
  implementation) with dry-run-by-default plans, `PlayTrack` typed config
  (internal default), staged-rollout `userFraction`, service-account
  credential by path via the ordered `CredentialResolver` policy
  (`OKA_PLAY_SERVICE_ACCOUNT_JSON`), the androidpublisher/v3 Edits flow
  (`PlayPublisherClient`: create edit → upload AAB → assign track →
  commit), and JWT → OAuth token exchange through googleapis_auth over an
  injectable transport (tests run fully offline).
