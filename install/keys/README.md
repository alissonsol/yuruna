# Yuruna release signing key

This folder holds the **public** half of the Yuruna release signing key,
in two encodings so a fresh host can verify a release with no extra tooling:

- `yuruna-release-signing.pub.pem` — PEM, for `openssl` (macOS / Linux).
- `yuruna-release-signing.pub.xml` — .NET `RSAKeyValue` XML, for Windows
  PowerShell 5.1's `RSACryptoServiceProvider.FromXmlString` (the `irm | iex`
  bootstrap runs on .NET Framework 4.8, which lacks `RSA.ImportFromPem`).

Both encode the same RSA-4096 public key.

## What it signs

The release process signs `install/install.sha256` (the SHA-256 of the three
bootstrap installers) with the **private** key, producing
`install/install.sha256.sig` (a detached PKCS#1 v1.5 / SHA-256 signature).
The verified install path (see [install/README.md](../README.md)) checks that
signature against the public key here, then checks the installer's own hash
against the verified `install.sha256`. This gives integrity against a
compromised CDN/mirror or a moved `main`, not just same-channel corruption.

## Fingerprint (verify OUT-OF-BAND before trusting)

```
SHA-256(DER public key) = 14fce044df5de1ebbac6fdeae8d4f87abac618393f06e32748b7ef4571c5c337
```

The signature only adds value if you trust the *right* public key. Confirm
this fingerprint through a channel separate from the repo (the value is also
recomputable: `openssl pkey -pubin -in yuruna-release-signing.pub.pem
-outform DER | openssl dgst -sha256`).

## The private key

The private key is **never** in the repo. It is held by the release owner and
read by the release script (`tools/Update-YurunaReleasePins.ps1`) only at
release time, from a path/env the owner supplies.

## Rotation / refresh

To rotate the signing key:

1. `openssl genpkey -algorithm RSA -pkeyopt rsa_keygen_bits:4096 -out new-private.pem`
   then `openssl rsa -in new-private.pem -pubout -out yuruna-release-signing.pub.pem`.
2. Regenerate the XML form:
   `$r=[System.Security.Cryptography.RSA]::Create(); $r.ImportFromPem((Get-Content yuruna-release-signing.pub.pem -Raw)); $r.ToXmlString($false)`.
3. Update the fingerprint above and re-publish it out-of-band.
4. Re-sign `install/install.sha256` (run the release script with the new key).
5. Store the new private key securely; destroy the old one.

---

Copyright (c) 2019-2026 by Alisson Sol et al.

Last review: 2026.07.10

Back to [Yuruna](../../README.md)
