# blocks-infra

Compose stack for the Blocks platform. Runs:

- **Infra** — MongoDB, Redis, RabbitMQ (with automatic Mongo seeding).
- **Apps** — 10 web APIs + 10 background workers, pulled from Docker Hub.
- **Edge** — `nginx-proxy` + `acme-companion` reverse proxy that auto-provisions Let's Encrypt certs for every web app subdomain.

Everything lives in a single `docker-compose.yml` split by **profiles** so you can start a slice (e.g. infra only for local dev) or the whole stack.

## Prerequisites

- [Docker](https://docs.docker.com/get-docker/) with Docker Compose.
- For the `edge` / `apps` profiles: a public host with DNS for `*.${DOMAIN}` pointing at it and ports `80` / `443` open.

## Profiles

| Profile | What it starts | When you use it |
| --- | --- | --- |
| `infra` | mongodb, mongodb-seed, redis, rabbitmq | Local dev — run alongside `dotnet run` on the host |
| `edge` | nginx-proxy + acme-companion | Deployment host — TLS termination + Let's Encrypt |
| `apps` | All 10 web APIs + 10 workers | Deployment host — every Blocks service |
| `os`, `iam`, `data`, `agents`, `logic`, `localization`, `monitor`, `release`, `studio`, `utilities` | The matching `*-api` + `*-worker` pair only | Bring up a single service group |

## Start the infrastructure (local dev)

```bash
docker compose --profile infra up -d
```

Or use `run.sh`, which does the same thing **and** exports the connection strings for `dotnet run`:

```bash
source run.sh        # brings up infra + exports BlocksSecret__* into your shell
dotnet run           # picks up MongoDB / Redis / RabbitMQ
```

This starts four containers:

| Container | Service | Host port |
| --- | --- | --- |
| `mongodb` | MongoDB 8 | `27018` |
| `mongodb-seed` | Seed runner (exits after restore) | — |
| `rabbitmq` | RabbitMQ 3 with Management UI | `5672`, `15672` |
| `redis` | Redis 8 | `6379` |

The `mongodb-seed` container waits for MongoDB to be healthy, then restores the `BlocksRootDb` and `BlocksConfiguration` databases from the BSON dump files in this repo. It exits automatically once the restore is complete.

## Run the full stack (deployment host)

```bash
# 1. Set the deployment variables in .env
#    DOMAIN=dev.mycompany.com
#    LETSENCRYPT_EMAIL=ops@mycompany.com
#    BLOCKS_VERSION=1.4.2
#
# 2. If any images are in a private registry:
docker login

# 3. Pre-pull every app image (optional but speeds up the first up)
docker compose --profile apps pull

# 4. Bring everything up
docker compose --profile infra --profile apps --profile edge up -d
```

Each web app is reachable at `https://<subdomain>.${DOMAIN}`:

| Service | Subdomain | Internal port |
| --- | --- | --- |
| blocks-os | `os` | 5000 |
| blocks-iam | `iam` | 5000 |
| blocks-data | `data` | 5000 |
| blocks-agents | `agents` | 8000 |
| blocks-logic | `logic` | 5000 |
| blocks-localization | `localization` | 5000 |
| blocks-monitor | `monitor` | 5000 |
| blocks-release | `release` | 5000 |
| blocks-studio | `studio` | 5000 |
| blocks-utilities | `utilities` | 5000 |

Workers are not exposed via nginx — they consume from RabbitMQ inside the Compose network.

## Bring up a single service group

Useful when infra is already running and you want to recycle one service pair:

```bash
docker compose --profile iam up -d       # iam-api + iam-worker only
docker compose --profile iam pull        # pull just IAM images
docker compose --profile iam restart     # restart just IAM
```

> The per-service profiles do **not** auto-start infra. Run `--profile infra` first (or leave it running).

## Update an app to a new image tag

```bash
# Bump BLOCKS_VERSION in .env (or override one image: line in docker-compose.yml)
docker compose --profile apps pull
docker compose --profile apps up -d      # recreates containers using new images
```

## Seed additional data with init-mongo.js

After the containers are running, seed the `ApiEndpointConfigs` collection into tenant databases:

```bash
mongosh "mongodb://${MONGO_USER}:${MONGO_PASS}@localhost:27018/?authSource=admin" --file init-mongo.js
```

To add more tenant databases, append their names to the `databases` array in [init-mongo.js](init-mongo.js).

## Configure your local application

`.env` holds the single source of truth for credentials and ports. It has two kinds of entries:

1. **Base variables** (`MONGO_*`, `REDIS_HOST_PORT`, `RABBITMQ_*`) — interpolated by `docker-compose.yml` into the containers, and also read by `run.sh` to compose the .NET connection strings at launch.
2. **Application config** (`BlocksSecret__*DatabaseName`, `BlocksSecret__EnableHsts`, `BLOCKS_VAULT_TYPE`) — non-derivable values consumed literally by .NET services.

To use with a Blocks service, copy `.env` **and** `run.sh` into the service root, then launch via the shim:

```bash
bash run.sh                          # runs `dotnet run`
bash run.sh dotnet run --no-launch-profile
bash run.sh dotnet test
```

`run.sh` sources `.env`, builds the connection strings below from the base variables, exports them, and `exec`s your command. Change `MONGO_USER` / `MONGO_PASS` / `MONGO_HOST_PORT` / `REDIS_HOST_PORT` / `RABBITMQ_*` in `.env` and every downstream connection string follows — no duplication.

| Variable | Source | Purpose |
| --- | --- | --- |
| `BlocksSecret__DatabaseConnectionString` | composed by `run.sh` | Primary MongoDB connection used by all services |
| `BlocksSecret__LogConnectionString` | composed by `run.sh` | MongoDB connection for log storage |
| `BlocksSecret__MetricConnectionString` | composed by `run.sh` | MongoDB connection for metric storage |
| `BlocksSecret__TraceConnectionString` | composed by `run.sh` | MongoDB connection for trace storage |
| `BlocksSecret__CacheConnectionString` | composed by `run.sh` | Redis cache connection |
| `BlocksSecret__MessageConnectionString` | composed by `run.sh` | RabbitMQ connection for service messaging |
| `BlocksSecret__LmtMessageConnectionString` | composed by `run.sh` | RabbitMQ connection for LMT (logging/metrics/tracing) events |
| `BlocksSecret__RootDatabaseName` | `.env` | Root database name (`BlocksRootDb`) |
| `BlocksSecret__Log/Metric/TraceDatabaseName` | `.env` | Database names for LMT data |
| `BlocksSecret__EnableHsts` | `.env` | Enable HTTP Strict Transport Security |
| `BLOCKS_VAULT_TYPE` | `.env` | Secret provider — `1` for local (reads from env), `2` for Azure Key Vault |

> Launching with plain `dotnet run` (no `run.sh`) will start the service without MongoDB/Redis/RabbitMQ connection strings. Always go through the shim for local development.

## RabbitMQ Management UI

Browse to [http://localhost:15672](http://localhost:15672) and log in with the `RABBITMQ_USER` / `RABBITMQ_PASS` credentials from `.env` (default `app` / `app`).

## Stop and clean up

```bash
# Stop containers, keep volumes (data persists)
docker compose --profile infra --profile apps --profile edge down

# Stop and remove all data volumes (Mongo data, Let's Encrypt certs, etc.)
docker compose --profile infra --profile apps --profile edge down -v
```

> `docker compose down` without `--profile` flags only stops services that are currently running and not profile-gated. Always pass the profiles you started with.

## Dump the current database state

Use [DumpDb.sh](DumpDb.sh) to export `BlocksRootDb` from the running container:

```bash
bash DumpDb.sh
```

Output is written to `/tmp/mongodump_out`.
