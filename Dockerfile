#build cpcache
FROM elixir as build

WORKDIR /cpcache

COPY cpcache .

ARG MIX_ENV=prod
RUN mix local.hex --force && \
    mix local.rebar --force && \
    mix deps.get && \
    mix release

# package it inside debian
FROM debian:buster-slim

RUN useradd -r -s /bin/bash -m -d /var/lib/cpcache cpcache && \
    mkdir -p /var/cache/cpcache && \
    chown -R cpcache:cpcache /var/cache/cpcache && \
    apt-get update && \
    apt-get install -y libssl1.1

COPY --from=build --chown=cpcache:cpcache /cpcache/_build/prod/rel/cpcache /var/lib/cpcache
COPY cpcache/conf/cpcache.toml /etc/cpcache/
COPY entrypoint.sh /usr/local/bin/

USER cpcache

ENTRYPOINT ["/usr/local/bin/entrypoint.sh"]

