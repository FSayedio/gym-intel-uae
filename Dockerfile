FROM elixir:1.20.4-otp-29-alpine@sha256:f95251968625b0b61716355b372b58b1916bb618b949de3d2e62fb803ad68784 AS source

ENV MIX_ENV=prod

WORKDIR /app

# Older audit tasks can silently accept cached records after registry failures.
RUN mix local.hex 2.6.0 --force && mix local.rebar --force

COPY mix.exs mix.lock ./
COPY config ./config

RUN mix deps.get --only prod && mix deps.compile

COPY lib ./lib
COPY priv ./priv

FROM source AS checks
ENV MIX_ENV=test
RUN apk add --no-cache openssl
COPY .formatter.exs ./
COPY test ./test
COPY scripts ./scripts
COPY kubernetes ./kubernetes
COPY data ./data
COPY grafana ./grafana
RUN mix deps.get --check-locked && mix compile --warnings-as-errors
CMD ["sh", "scripts/ci-checks.sh"]

FROM source AS builder
RUN cat /etc/alpine-release && test "$(cat /etc/alpine-release)" = 3.24.3 \
    && mix compile --warnings-as-errors && mix release gym_intel

# Match the builder's musl/Alpine runtime, without shipping Mix/Hex/Rebar.
FROM alpine:3.24.3@sha256:be2656061b536c1883c4034790e21d0a09c5aaaf51968b89368a3c0371ea2c9a AS runtime
RUN apk add --no-cache libstdc++ ncurses-libs libcrypto3 libssl3 liblksctp ca-certificates \
    && addgroup -S -g 10001 gym_intel \
    && adduser -S -D -H -u 10001 -G gym_intel gym_intel
WORKDIR /app
COPY --from=builder /app/_build/prod/rel/gym_intel ./
ENV HOME=/tmp \
    RELEASE_TMP=/tmp/gym-intel \
    RELEASE_DISTRIBUTION=none \
    ERL_CRASH_DUMP=/tmp/gym-intel-crash.dump
USER 10001:10001
CMD ["bin/gym_intel", "start"]
