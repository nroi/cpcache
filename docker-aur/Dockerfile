# This docker image is used to test if the PKGBUILD currently published on AUR
# builds and installs without issues.

FROM archlinux/base

RUN pacman -Syu --noconfirm --noprogressbar --quiet base-devel git sudo

RUN useradd -r -s /bin/bash cpcache
RUN usermod -g wheel cpcache

RUN echo "%wheel ALL=(ALL) NOPASSWD: ALL" >> /etc/sudoers

USER cpcache

WORKDIR /tmp

RUN curl -s --remote-name 'https://aur.archlinux.org/cgit/aur.git/snapshot/cpcache-git.tar.gz' && \
    tar xf cpcache-git.tar.gz

WORKDIR /tmp/cpcache-git

RUN makepkg --noprogressbar --noconfirm --nocolor -s

USER root

RUN pacman -U --noconfirm --noprogressbar *.tar.xz

User cpcache

ENV ELIXIR_ERL_OPTIONS "-sname cpcache"

ENTRYPOINT /usr/share/cpcache/bin/cpcache foreground
