# Pinned runtime for feature building and backtesting.
#
# A separate image from ingest/ on purpose: the loaders need network access to
# government APIs and no numeric stack, this needs a numeric stack and no
# network. Sharing one image would give each job the other's attack surface.
#
# Nothing is installed on the host. CLAUDE.md forbids it, and beyond that a
# model whose result depends on whatever was in the developer's environment is
# not reproducible -- which is the entire claim a backtest makes.
FROM python:3.12-slim-bookworm

# Versions pinned exactly, not floated. A minor scikit-learn release can change
# a default and move a reported MAE, and a metric that moves without the code
# moving is worse than no metric.
RUN pip install --no-cache-dir \
    "psycopg[binary]==3.2.3" \
    "numpy==2.1.3" \
    "scikit-learn==1.5.2"

RUN useradd --create-home --uid 10004 mlops
WORKDIR /mlops
USER mlops

ENTRYPOINT ["python"]
