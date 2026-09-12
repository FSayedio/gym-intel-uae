FROM elixir:1.20.4-otp-29-alpine

ENV MIX_ENV=prod

WORKDIR /app

RUN mix local.hex --force && mix local.rebar --force

COPY mix.exs mix.lock ./
COPY config ./config

RUN mix deps.get --only prod && mix deps.compile

COPY lib ./lib
COPY priv ./priv

RUN mix compile --warnings-as-errors

CMD ["sh", "-c", "mix ecto.migrate && exec mix run --no-halt"]
