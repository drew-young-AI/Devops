---
type: explanation
title: 疾管署來源的 CA 中繼憑證
description: "Why an intermediate CA certificate is pinned here: od.cdc.gov.tw serves the wrong intermediate, so the chain cannot be built without it."
tags:
  - ingest
  - tls
  - provenance
timestamp: 2026-08-18T13:40:00+08:00
---

# twca-ssl-ca-2023.pem

`od.cdc.gov.tw` **serves the wrong intermediate certificate.**

    leaf   *.cdc.gov.tw
           issuer = TWCA SSL Certification Authority        (OU=SSL Sub-CA)
    sent   TWCA Secure SSL Certification Authority          <- different CA
           issuer = TWCA Global Root CA

The chain does not link. Browsers hide this by fetching the missing
intermediate from the leaf's AIA extension; `curl` and Python do not, so both
fail with `CERTIFICATE_VERIFY_FAILED` / `unknown CA`.

This file is the correct intermediate, retrieved from the AIA URL published
in the leaf certificate itself:

    http://sslserver.twca.com.tw/cacert/Cyber_SSL_2023.crt
    subject = TWCA SSL Certification Authority   (OU=SSL Sub-CA)
    issuer  = TWCA CYBER Root CA

`TWCA CYBER Root CA` is present in certifi's Mozilla bundle, so
`certifi + this file` builds a complete, verified chain. It is **not** in the
macOS system root store, which is why the system `curl` fails even with a
browser User-Agent.

## Why not `-k` / `verify=False`

Disabling verification to work around a broken chain removes authentication
of the source entirely -- on a pipeline whose entire output is "these are the
official case counts". The failure mode being avoided is not an inconvenience;
it is ingesting numbers from whoever answers that address.

## Rotation

The pinned intermediate expires with TWCA's schedule, not the leaf's. When
ingestion starts failing on verification, re-fetch from the AIA URL in the
then-current leaf certificate:

    echo | openssl s_client -connect od.cdc.gov.tw:443 -servername od.cdc.gov.tw \
      | openssl x509 -noout -text | grep -A2 'Authority Information Access'
