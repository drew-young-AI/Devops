FROM python:3.12-slim AS base

# psycopg[binary] ships prebuilt wheels, so no libpq-dev / gcc in the image.
# A build toolchain left in a runtime image is both weight and attack surface.
RUN pip install --no-cache-dir "psycopg[binary,pool]==3.2.3"

# Non-root. The platform's Trivy gate flags root containers, and a service
# reachable through a reverse proxy has no reason to run privileged.
RUN useradd --create-home --uid 10002 twin
WORKDIR /app
COPY app/ /app/
USER twin

EXPOSE 8080
CMD ["python", "/app/app.py"]
