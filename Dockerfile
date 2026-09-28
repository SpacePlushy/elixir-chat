# Builds a self-contained OTP release, then copies it into a slim image
# that has no Elixir or Erlang installed (the release bundles the runtime).

ARG ELIXIR_VERSION=1.20.4
ARG OTP_VERSION=29.1.1
ARG DEBIAN_VERSION=trixie-20260918-slim

ARG BUILDER_IMAGE="hexpm/elixir:${ELIXIR_VERSION}-erlang-${OTP_VERSION}-debian-${DEBIAN_VERSION}"
ARG RUNNER_IMAGE="debian:${DEBIAN_VERSION}"

# -- Build ---------------------------------------------------------------------
FROM ${BUILDER_IMAGE} AS builder

WORKDIR /app
ENV MIX_ENV=prod

RUN mix local.hex --force && mix local.rebar --force

# Dependencies change less often than code, so they get their own cached layers.
COPY mix.exs mix.lock ./
RUN mix deps.get --only $MIX_ENV
RUN mkdir config
COPY config/config.exs config/${MIX_ENV}.exs config/
RUN mix deps.compile

COPY priv priv
COPY lib lib
RUN mix compile

# runtime.exs is read when the release boots, so changing it needs no recompile.
COPY config/runtime.exs config/
RUN mix release

# -- Run -----------------------------------------------------------------------
FROM ${RUNNER_IMAGE}

RUN apt-get update -y \
  && apt-get install -y --no-install-recommends libstdc++6 openssl libncurses6 libsctp1 locales ca-certificates \
  && apt-get clean \
  && rm -f /var/lib/apt/lists/*_*

RUN sed -i '/en_US.UTF-8/s/^# //g' /etc/locale.gen && locale-gen
ENV LANG=en_US.UTF-8 LANGUAGE=en_US:en LC_ALL=en_US.UTF-8

WORKDIR /app
RUN chown nobody /app

# A single node: no need for Erlang distribution (or the epmd daemon).
ENV MIX_ENV=prod RELEASE_DISTRIBUTION=none

COPY --from=builder --chown=nobody:root /app/_build/prod/rel/chat ./

USER nobody

# HTTP (overridden by $PORT on Render) and telnet.
EXPOSE 4000 4040

CMD ["/app/bin/chat", "start"]
