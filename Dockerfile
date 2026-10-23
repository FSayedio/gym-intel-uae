FROM elixir:1.20.4-otp-29-alpine AS source

ENV MIX_ENV=prod

WORKDIR /app

RUN mix local.hex --force && mix local.rebar --force

COPY mix.exs mix.lock ./
COPY config ./config

RUN mix deps.get --only prod && mix deps.compile

COPY lib ./lib
COPY priv ./priv

FROM source AS checks
ENV MIX_ENV=test
COPY .formatter.exs ./
COPY test ./test
COPY scripts ./scripts
COPY data ./data
COPY grafana ./grafana
RUN mix deps.get --check-locked && mix compile --warnings-as-errors
CMD ["sh", "scripts/ci-checks.sh"]

FROM source AS builder
RUN test "$(cat /etc/alpine-release)" = 3.24.1 \
    && mix compile --warnings-as-errors && mix release gym_intel

# Match the builder's musl/Alpine runtime, without shipping Mix/Hex/Rebar.
FROM alpine:3.24.1 AS runtime
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
