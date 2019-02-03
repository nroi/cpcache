FROM base/archlinux

EXPOSE 7070

# Elixir emits warnings when an encoding other than UTF8 is set:
RUN echo 'en_US.UTF-8 UTF-8' >> /etc/locale.gen && \
    locale-gen
ENV LANG en_US.UTF-8

RUN pacman -Syu --noconfirm git elixir sudo

RUN useradd -r -s /bin/bash -m -d /var/lib/cpcache cpcache && \
    mkdir -p /var/cache/cpcache/pkg/{core,extra,multilib,testing,community}/os/x86_64 && \
    mkdir -p /var/cache/cpcache/state && \
    mkdir /etc/cpcache && \
    chown -R cpcache:cpcache "/var/cache/cpcache"

WORKDIR /var/lib/cpcache
RUN sudo -u cpcache git clone https://github.com/nroi/cpcache && \
    sudo -u cpcache mix local.hex --force && \
    sudo -u cpcache mix local.rebar --force && \
    sudo -u cpcache sh -c "cd cpcache && mix deps.get && mix compile" && \
    cp /var/lib/cpcache/cpcache/conf/cpcache.toml /etc/cpcache/

USER cpcache
WORKDIR /var/lib/cpcache/cpcache
ENTRYPOINT iex -S mix
