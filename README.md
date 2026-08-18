# Njord

Njord is a self-hosted accounting appliance. One container packages PostgreSQL,
PostgREST, the web gateway, and the compiled Elm interface. The published image
supports Linux AMD64 and ARM64.

## Design

Financial rules, validation, authorization, report definitions, labels, and
translations live in PostgreSQL. PostgREST exposes the SQL API. Elm renders the
returned page and report structures; it does not contain business logic. The
gateway handles routing and GitHub OAuth.

An installation has one PostgreSQL cluster, one control database, and one
physical database per Book. PostgreSQL uses only its private Unix socket: IP
networking and password authentication are disabled.

## Run the appliance

Install Docker with Compose v2, then:

```sh
cp .env.example .env
docker network create njord-edge
docker compose pull njord
NJORD_INSTALL_EXAMPLES=1 NJORD_ALLOW_UNAUTHENTICATED=1 \
  docker compose up --no-build -d
```

Open `http://127.0.0.1:8080`. This local mode is deliberately unauthenticated;
never expose it to the Internet. Data persists in the `njord-data` volume.

Anonymous pulls require the GHCR package to be public. For a private package,
log in first with a classic GitHub token carrying `read:packages`:

```sh
printf '%s' "$CR_PAT" | docker login ghcr.io -u YOUR-GITHUB-LOGIN --password-stdin
```

## GitHub authentication

Create a GitHub OAuth App with callback URL
`https://YOUR-HOST/auth/callback`. Set these values in `.env`:

```dotenv
NJORD_ADMIN_GITHUB_LOGIN=your-github-login
NJORD_GITHUB_CLIENT_ID=your-client-id
NJORD_PUBLIC_URL=https://YOUR-HOST
```

Create three mode-0600 files under `secrets/`:

- `github_client_secret`, containing the OAuth App secret;
- `session_secret`, containing 32 random bytes or more; and
- `postgrest_jwt_secret`, containing 32 random bytes or more.

Attach your HTTPS nginx service to `njord-edge`, proxy to
`http://njord:8080`, and start Njord:

```sh
docker compose -f docker-compose.yml -f compose.github.yaml pull njord
docker compose -f docker-compose.yml -f compose.github.yaml up --no-build -d
```

The image is published as `ghcr.io/chapeltech/njord`. Pin a release tag or
digest when storing real data.

## Documentation

- [Architecture](ARCHITECTURE.md)
- [Operations and backup](OPERATIONS.md)
- [Security model](SECURITY.md)
- [Project plan](PLAN.md)

Run the automated checks with `npm test`, `npm run test:compose`, and
`npm run test:compose-oauth`.
