FROM elixir

EXPOSE 7070

RUN useradd -r -s /bin/bash -m -d /var/lib/cpcache cpcache && \
    mkdir -p /var/cache/cpcache/pkg/{core,extra,multilib,testing,community}/os/x86_64 && \
    mkdir -p /var/cache/cpcache/state && \
    mkdir /etc/cpcache && \
    chown -R cpcache:cpcache "/var/cache/cpcache"

WORKDIR /var/lib/cpcache

COPY --chown=cpcache:cpcache cpcache /var/lib/cpcache/
COPY cpcache/conf/cpcache.toml /etc/cpcache/

USER cpcache
RUN mix local.hex --force && \
    mix local.rebar --force && \
    mix deps.get && \
    mix compile

ENTRYPOINT iex -S mix
