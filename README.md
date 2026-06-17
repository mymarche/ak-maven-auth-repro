# Maven + Artifact Keeper Auth Reproduction

Reproduces the bug: Maven cannot authenticate against Artifact Keeper when `AK_GUEST_ACCESS_ENABLED=false` because AK returns 401 without a `WWW-Authenticate` header, so Maven never retries with credentials.

## Quick Start

```bash
git clone https://github.com/mymarche/ak-maven-auth-repro.git
cd ak-maven-auth-repro
docker compose up --wait

# Tests run automatically — check results:
docker compose logs maven-test
```

## How It Works

The compose stack starts 4 containers:
1. `postgres` — database
2. `backend` — Artifact Keeper with `AK_GUEST_ACCESS_ENABLED=false`
3. `setup` — runs `setup.sh`: creates test-maven repo + uploads a dummy artifact, then waits
4. `maven-test` — runs `test.sh` automatically once setup is healthy, then exits

`test.sh` runs two tests:

1. **Test 1** — `mvn dependency:resolve` WITHOUT `preemptiveAuth`. Expected to fail with 401 (the bug).
2. **Test 2** — `mvn dependency:resolve` WITH `-Daether.connector.http.preemptiveAuth=true` (via `.mvn/maven.config`). Expected to succeed (the fix).

## What to Look At

### Backend logs

```bash
docker compose logs -f backend
```

Key log events:
- First boot — admin user creation: `provision admin user`
- Guest access guard: `guest access guard: 401 with no WWW-Authenticate`
- Setup middleware (if password is in insecure list): `setup guard is active`, `setup: mutations blocked`
- Successful preemptive auth request: status 200

### Network flow

In Test 1 Maven gets 401 without `WWW-Authenticate` → doesn't know to send Basic auth → connection fails.

In Test 2 Maven sends `Authorization: Basic ...` on the first request, bypassing the 401 entirely.

### .mvn/maven.config

The fix is in `.mvn/maven.config`:

```
-Daether.connector.http.preemptiveAuth=true
```

## Commands

```bash
# Follow backend logs
docker compose logs -f backend

# Check test results
docker compose logs maven-test

# Full reset (fresh DB, fresh tests)
docker compose down -v && docker compose up --wait

# Rerun tests only (without recreating the stack)
docker compose run --rm maven-test
```

## File Structure

| File | Purpose |
|------|---------|
| `docker-compose.yml` | Postgres + backend + setup + maven-test containers |
| `setup.sh` | Login, create repository, upload test artifact |
| `test.sh` | Tests: without preemptive auth (401) and with preemptive auth (200) |
