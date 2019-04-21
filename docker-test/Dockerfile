FROM elixir

EXPOSE 7070

RUN useradd -r -s /bin/bash -m -d /var/lib/cpcache cpcache && \
    mkdir -p /var/cache/cpcache/pkg/core/os/x86_64 && \
    mkdir -p /var/cache/cpcache/pkg/extra/os/x86_64 && \
    mkdir -p /var/cache/cpcache/pkg/multilib/os/x86_64 && \
    mkdir -p /var/cache/cpcache/pkg/testing/os/x86_64 && \
    mkdir -p /var/cache/cpcache/pkg/community/os/x86_64 && \
    mkdir -p /var/cache/cpcache/state && \
    mkdir /etc/cpcache && \
    chown -R cpcache:cpcache "/var/cache/cpcache"

WORKDIR /var/lib/cpcache

# Workaround: We basically want to say "Rebuild everything from this point on",
# so we just have to change the .marker file in order to invalidate all
# statements up to and including this COPY statement.
COPY .marker /dev/null

COPY --chown=cpcache:cpcache cpcache /var/lib/cpcache/
COPY cpcache/conf/cpcache.toml /etc/cpcache/

USER cpcache
RUN mix local.hex --force && \
    mix local.rebar --force && \
    mix deps.get && \
    mix compile

ENTRYPOINT iex -S mix test
