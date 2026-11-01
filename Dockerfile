# syntax=docker/dockerfile:1
#
# Multi-stage build for the MuchToDo Golang backend.
#
# Build context is the ROOT of this repository. The application source lives in
# the `much-to-do` git submodule, so clone with:
#     git clone --recurse-submodules <this repo>
#
#   Stage 1 (builder): compiles a statically linked binary with the Go toolchain.
#   Stage 2 (runtime): copies only that binary into a minimal Alpine image.
#
# The final image contains no compiler, no module cache and no source code.

# ---------------------------------------------------------------------------
# Stage 1 - builder
# ---------------------------------------------------------------------------
# go.mod of the application declares `go 1.25.1`, so the builder image must be
# at least 1.25 or the build fails with a toolchain error.
FROM golang:1.25-alpine AS builder

WORKDIR /src

# Copy the module files first and download dependencies as their own layer.
# This layer is only invalidated when go.mod or go.sum changes, so day-to-day
# code edits reuse the cached dependency download.
COPY much-to-do/Server/MuchToDo/go.mod much-to-do/Server/MuchToDo/go.sum ./
RUN go mod download

# Now copy the application source.
COPY much-to-do/Server/MuchToDo/ ./

# CGO_ENABLED=0 produces a statically linked binary with no libc dependency,
# which is what lets the runtime stage stay minimal.
# -trimpath removes local filesystem paths from the binary.
# -ldflags "-s -w" strips the symbol table and DWARF debug info (smaller image).
RUN CGO_ENABLED=0 GOOS=linux go build \
        -trimpath \
        -ldflags="-s -w" \
        -o /out/much-to-do \
        ./cmd/api/main.go

# ---------------------------------------------------------------------------
# Stage 2 - runtime
# ---------------------------------------------------------------------------
FROM alpine:3.22 AS runtime

# ca-certificates: required for any outbound TLS call.
# tzdata: correct timestamps in the application's structured logs.
# wget is already present via busybox and is used by the HEALTHCHECK below.
RUN apk add --no-cache ca-certificates tzdata

# Create an unprivileged user and group. The application never needs root:
# it binds to 8080 (above 1024) and writes nothing to disk.
RUN addgroup -S -g 10001 appgroup \
 && adduser  -S -u 10001 -G appgroup -h /app -s /sbin/nologin appuser

WORKDIR /app

# --- Why this .env file exists -------------------------------------------
# internal/config/config.go loads configuration with viper using
# AutomaticEnv() + Unmarshal(). Viper's Unmarshal only populates struct fields
# for keys it already knows about (from a config file or SetDefault), and the
# application only registers defaults for PORT, ENABLE_CACHE and
# JWT_EXPIRATION_HOURS. Keys such as MONGO_URI and DB_NAME are therefore not
# registered, and passing them purely as container environment variables can
# unmarshal as empty strings - the app then exits with a MongoDB connection
# error that looks like a networking problem but is not.
#
# Shipping this placeholder .env registers every key with viper. Real values
# are supplied by docker-compose via `environment:` and take precedence,
# because viper ranks environment variables above config-file values.
RUN printf '%s\n' \
    'PORT=8080' \
    'MONGO_URI=' \
    'DB_NAME=much_todo_db' \
    'JWT_SECRET_KEY=' \
    'JWT_EXPIRATION_HOURS=72' \
    'ENABLE_CACHE=false' \
    'REDIS_ADDR=' \
    'REDIS_PASSWORD=' \
    'LOG_LEVEL=INFO' \
    'LOG_FORMAT=json' \
    > /app/.env

# Copy only the compiled binary from the builder stage.
COPY --from=builder /out/much-to-do /app/much-to-do

RUN chown -R appuser:appgroup /app

USER appuser

EXPOSE 8080

# The application's /health endpoint pings MongoDB and returns 503 when the
# database is unreachable. `wget --spider` exits non-zero on any non-2xx
# response, so the container is only reported healthy when the API can serve
# requests AND reach its database.
HEALTHCHECK --interval=30s --timeout=5s --start-period=20s --retries=3 \
    CMD wget --quiet --tries=1 --spider http://127.0.0.1:8080/health || exit 1

ENTRYPOINT ["/app/much-to-do"]
