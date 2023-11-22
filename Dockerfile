# Find eligible builder and runner images on Docker Hub. We use Ubuntu/Debian instead of
# Alpine to avoid DNS resolution issues in production.
#
# https://hub.docker.com/r/hexpm/elixir/tags?page=1&name=ubuntu
# https://hub.docker.com/_/ubuntu?tab=tags
#
#
# This file is based on these images:
#
#   - https://hub.docker.com/r/hexpm/elixir/tags - for the build image
#   - https://hub.docker.com/_/debian?tab=tags&page=1&name=bullseye-20210902-slim - for the release image
#   - https://pkgs.org/ - resource for finding needed packages
#   - Ex: hexpm/elixir:1.12.0-erlang-24.0.1-debian-bullseye-20210902-slim
#
ARG BUILDER_IMAGE="hexpm/elixir:1.16.3-erlang-26.2.5-debian-bookworm-20240612-slim"
ARG RUNNER_IMAGE="debian:bookworm-20240612-slim"

ARG LIVE_BEATS_GITHUB_CLIENT_ID=""
ARG LIVE_BEATS_GITHUB_CLIENT_SECRET=""

FROM ${BUILDER_IMAGE} as developer

# install system dependencies
RUN apt-get -y update \
    && apt-get install -y \
        build-essential \
        git \
    && apt-get clean \
    && rm -rf /var/lib/apt_lists/*_*

WORKDIR /app

# install hex + rebar
RUN mix do local.hex --force, local.rebar --force

# install application dependencies
COPY mix.exs mix.lock ./
COPY config/config.exs config/dev.exs config/test.exs config/
RUN mix do deps.get, deps.compile

COPY priv priv
COPY lib lib
COPY assets assets
COPY test test
RUN mix do assets.deploy, compile

EXPOSE 4000

FROM ${BUILDER_IMAGE} as builder

# install build dependencies
RUN apt-get update -y && apt-get install -y build-essential git curl ffmpeg \
    && apt-get clean && rm -f /var/lib/apt/lists/*_*

# prepare build dir
WORKDIR /app

# install hex + rebar
RUN mix local.hex --force && \
    mix local.rebar --force

# set build ENV
ENV MIX_ENV="prod"
ENV BUMBLEBEE_CACHE_DIR="/app/.bumblebee"

# install mix dependencies
COPY mix.exs mix.lock ./
RUN mix deps.get --only $MIX_ENV
RUN mkdir config

# copy compile-time config files before we compile dependencies
# to ensure any relevant config change will trigger the dependencies
# to be re-compiled.
COPY config/config.exs config/${MIX_ENV}.exs config/
RUN mix deps.compile

COPY priv priv

# Compile the release
COPY lib lib

# note: if your project uses a tool like https://purgecss.com/,
# which customizes asset compilation based on what it finds in
# your Elixir templates, you will need to move the asset compilation
# step down so that `lib` is available.
COPY assets assets

# compile assets
RUN mix assets.deploy

RUN mix compile
RUN mix run -e 'LiveBeats.Application.load_serving()' --no-start

# Changes to config/runtime.exs don't require recompiling the code
COPY config/runtime.exs config/

COPY rel rel
RUN mix release

# start a new build stage so that the final image will only contain
# the compiled release and other runtime necessities
FROM ${RUNNER_IMAGE}

RUN apt-get update -y \
    && apt-get install -y libstdc++6 openssl libncurses5 locales curl ffmpeg s3fs \
    && apt-get clean \
    && rm -f /var/lib/apt/lists/*_*

# Set the locale
RUN sed -i '/en_US.UTF-8/s/^# //g' /etc/locale.gen \
    && locale-gen

ENV LANG en_US.UTF-8
ENV LANGUAGE en_US:en
ENV LC_ALL en_US.UTF-8

# Set local user
RUN groupadd --gid 1000 app \
    && useradd \
        --uid 1000 \
        --gid app \
        --home-dir /home/app \
        --create-home \
        app

WORKDIR "/app"
RUN chown app:app /app
ENV BUMBLEBEE_CACHE_DIR="/app/.bumblebee"

# Only copy the final release from the build stage
COPY --from=builder --chown=app:app /app/_build/prod/rel/live_beats ./
# COPY --from=builder --chown=app:app /app/.postgresql/ ./.postgresql
COPY --from=builder --chown=app:app /app/.bumblebee/ ./.bumblebee

USER app

# Set the runtime ENV
ENV ECTO_IPV6="true"
ENV ERL_AFLAGS="-proto_dist inet6_tcp"

CMD /app/bin/server
