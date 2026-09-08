// SYNTHETIC TEST FIXTURE — NOT A SECRET.
//
// This RSA key was generated specifically for this test fixture and is
// published here on purpose. It guards nothing, signs nothing real, and is
// useless outside these offline tests (the transport is a scripted fake).
// It exists so the JWT → OAuth token-exchange path can be exercised
// without any network and without any real credential material in the
// repo (ADR-0014: no secret material, ever — even fakes must be obviously
// synthetic).
//
// Every string below that looks like a value is a placeholder. The redaction
// tests use [syntheticSecretMarkers] to prove none of this fixture's
// material ever reaches PipelineState, logs, plans, or result data.

/// The service-account JSON *shape* googleapis_auth requires — every value
/// synthetic.
const String syntheticServiceAccountJson = r'''
{
  "type": "service_account",
  "project_id": "synthetic-test-project",
  "private_key_id": "synthetic-test-key-id-not-a-real-key",
  "private_key": "-----BEGIN PRIVATE KEY-----\nMIIEvwIBADANBgkqhkiG9w0BAQEFAASCBKkwggSlAgEAAoIBAQC8uVG3RlwIkdqb\nh7tYx61aSeliRtEPfqR4bGnLibNrj2hdEvTzs2kdyq84fxfkwrTaMIubPeAE+rtZ\nMnKcRw+QwfejQWOqpgpZKSGaXCdQsKwB50630PdPVRAvkPbd89yzNRmsJtkpwbe9\nH32yZ7WzRyk5QBJ3FZeGLS7157gh/DMjNeLJxkyA81bNGiCVwfnmw9vh1LiwlWkP\nHibvVlrnJztTwaUrQHxladJKqXxPE0L3hgfxZ+Uh8NarNzFkNBdW2qw8wPQWoRHI\nKr+JcWqw+68wasUfs5O9X5j3JZ3Svb1c5DM2TwsIxIip8S0ebU1rYhtP7WU+qBNz\nJGopSN5nAgMBAAECggEAHWsl+dPV9OAHm8cExUobE8AByXgQjsHHEZ6Uv02v0kyA\nkEGsPXDyKdq2hbAKIXbYikqW+JQkn6IWIkli5EmPe5lA6QoAZ1GKu2tV+aHz3vgr\nWACenLjOVGeGJmQKl360IJtebR+BKqkv4yNNjMnt4QxuuKXsOvP6ssfIUjzUzzck\nmi3553i/S2eTJF/5C9YW8lG8mkIlzTRSLWVpxjgIrqHOTI6DbMJQCyMSrHqmZSd/\nHPw8PQA3qozOpJ+/sVeR3hCiS0B/AlD9HM0hJB0KYgguhQynKVh+3+5Viv9mhKhr\nx+5/nl/+AjOGOn7J0q3574tLBmKsfe3gxdnGo74dwQKBgQDdOckcqwAqkOE7sP5g\n7CFEq+43xpGEOiDGw6m70meNyKNisY9zrdR/yvjLNHUeOKZpmn+tCnq8H710gf+1\n6TEtdGPwa1Sx/PMKyCJklb4NunXR2HxQ7So7VEkClQjRkf0Ffh8z/CCnfXgX05+y\nyUAPjOZOvuZOWqvUyQtGwQf4wwKBgQDaY6Wa4fcUAFZNVClx/D41Ho0ZFK2nJdBD\noUQgPyr4QO75WegFGqWaCTkmxa7IV24lOqkbHyWTY4RX5rN3CvebXBYZI77+31fW\n8VeXqcXYEyA2a+YhDXVK9+SIhHgsk8Yes8/VaEyMyTSS93h2Fgij+GnklLGd/fyt\noZ1V/OIJjQKBgQC+IvdGK3amHwVmb1YC6ZAiXH8O8xyIgAlBrFOKuWkFREehAKkh\nrGqyNzokNH7graHhq8dGa3ZXkBQeOckUiUsaHSn0LduKarRdNOvSdZz2Yab358/Z\nIi2k9mkVzg/ZR1cnTGH3JSDPs5fvKpTcbfogI2KilZKOD4IWDYEim6+FTwKBgQDQ\n9JsVkLOJ7bClmKt3JrSWur6iisiEr4ePzhOTDx2cHvUInF+F0rM0qTKHyImtown+\nkRwQmUKovYV5XYHFmzbC7d8u+qba0vQG8zCuKoDkd5hQufidE3Vw37NIdAdQD6x2\n3/Ex7fOgmTu2ixY1Vmu6CAu57BPuaYCE2afjCG12WQKBgQDPOf+8C0IzSklOA9+N\nK7yLbxSDym5MbISmh8POB1qU/fLIcz7R80FK5Hqb1ZYd5vH/NzFpg+VJaC7tGJr/\nncTcr0wX7etp72qdC8ef7kAy1RvnhE77daRP1e4HRHiFJD/K0SfQR65RPj1eEz+1\nI5Anu6VXyPblE1G8ti0geSG3mg==\n-----END PRIVATE KEY-----\n",
  "client_email": "synthetic-test-account@synthetic-test-project.iam.gserviceaccount.com",
  "client_id": "000000000000000000000",
  "auth_uri": "https://accounts.google.com/o/oauth2/auth",
  "token_uri": "https://oauth2.googleapis.com/token",
  "auth_provider_x509_cert_url": "https://www.googleapis.com/oauth2/v1/certs",
  "client_x509_cert_url": "https://certurl.example.test/synthetic.pem"
}
''';

/// Strings that must never appear outside the fixture file itself (the
/// redaction law's forbidden material, in test form).
const List<String> syntheticSecretMarkers = [
  'MIIEvwIBADANBgkqhkiG9w0BAQEFAASCBKkwggSlAgEAAoIBAQC8uVG3RlwIkdqb',
  'synthetic-test-account@synthetic-test-project.iam.gserviceaccount.com',
  '000000000000000000000',
];

/// A minimal fake AAB payload (bytes, not a real bundle — the upload tests
/// only assert the bytes travel verbatim).
final List<int> syntheticAabBytes = List<int>.generate(64, (final i) => i);
