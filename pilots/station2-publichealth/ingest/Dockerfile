# The ingestion runtime, pinned.
#
# The loaders were previously run against whatever interpreter happened to be
# on PATH. That works until it does not: the host's python is 3.9, has no
# psycopg, and would need a global install to get one -- which this machine
# forbids, correctly. A pipeline whose result depends on which shell you were
# in is not reproducible, and reproducibility is the whole claim being made
# about this data.
FROM python:3.12-slim

# Same psycopg version as the service image, so the loader and the reader
# cannot disagree about how a value round-trips. certifi supplies the CA
# bundle; the CDC's missing intermediate is pinned in certs/ and loaded on top.
# defusedxml replaces the stdlib XML parser for the NLSC geography feed. Added
# 2026-08-19, the first time SAST was ever pointed at this directory: CI had
# excluded ingest/ entirely, so ~2,000 lines of loader were never scanned. The
# very first scan returned an ERROR-severity finding here. Stdlib
# xml.etree.ElementTree expands entities, so a hostile or corrupted response can
# cause a billion-laughs denial of service; the parse is of a government HTTPS
# endpoint, which lowers the likelihood but does not make the parser safe.
RUN pip install --no-cache-dir "psycopg[binary]==3.2.3" "certifi==2024.8.30" \
    "defusedxml==0.7.1"

RUN useradd --create-home --uid 10003 ingest
WORKDIR /ingest
USER ingest

ENTRYPOINT ["python"]
