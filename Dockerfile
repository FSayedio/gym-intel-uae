FROM elixir:1.20.4-otp-29-alpine

ENV MIX_ENV=prod

WORKDIR /app

COPY mix.exs ./
COPY lib ./lib

RUN mix compile --warnings-as-errors

CMD ["mix", "run", "--no-halt"]
