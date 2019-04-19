# cpcache

cpcache is a central cache for pacman, the package manager of Arch Linux. It requires little
configuration, does not bother you with 404 errors and it allows you to utilize the full bandwidth
even as multiple clients download the same file at the same time.


## How it works

For each incoming GET request, cpcache checks if it can serve the request from
cache. If so, the file is sent to the client while it is being read from the local
file system. Otherwise, the file is sent while it is being downloaded from an
ordinary pacman mirror.
In either case, the client will get an immediate response, i.e., files need not be
downloaded from the server or read from the file system entirely before a response is
sent to the client.
No caching is done for database files, cpcache will send a redirect response
instead.

## Comparison with other shared pacman caches
Most importantly, cpcache allows you to share bandwidth when multiple clients are downloading the same
file at the same time. For instance, suppose a second client requests a file that has been
downloaded to 30% by the first client. The second client will obtain at least 30% of that file with
whatever speed your LAN provides. Afterwards, both clients continue to download with the full speed
provided by your ISP.

A number of different caching methods are listed in the
[wiki](https://wiki.archlinux.org/index.php?title=Pacman/Tips_and_tricks&redirect=no#Network_shared_pacman_cache),
let's compare cpcache with each of them.
* Read-only cache using a web server such as darkhttp:
  This is messy since it will return lots of 404s. With cpcache, uncached packages will be downloaded as
  if you were downloading them directly from the remote mirror, while also making them available for
  subsequent requests.
* Read-write caches such as [pacserve](https://wiki.archlinux.org/index.php/Pacserve) or
  [pacredir](https://github.com/eworm-de/pacredir#pacredir):
  pacserve and pacredir are distributed while cpcache is centralized. A distributed solution is your
  only option if you don't have a device in your LAN which is running 24/7. If, on the other hand, you
  do have such a device, you may prefer a centralized solution that keeps all your cached packages
  at one place. This allows you to just set pacman's `CacheDir` to a tmpfs instead of storing
  packages redundantly. Also, packages that are cached once are always available, not only if the
  machine that cached it happens to be online.
* Reverse proxy cache using NGINX: Apart from the fact that cpcache can utilize the full bandwidth
  even with multiple concurrent downloads, the setup described in the wiki is quite similar to
  cpcaches approach. However, cpcache provides additional features. For instance, it obtains the
  most recent list of official mirrors and attempts to choose a fast mirror for you. This means you
  will not have to maintain a mirror list yourself.
* Proxy cache using [squid](https://wiki.archlinux.org/index.php/Package_Proxy_Cache):
  From the perspective of the client, cpcache acts like an additional mirror, so that pacman will
  try another mirror if the machine running cpcache is unreachable. Configuring a proxy
  cache using squid on the other hand means that all HTTP requests first have to be routed through
  the machine running squid, which may be undesirable if you cannot rely on that machine being
  always available. Especially on laptops, you'd have to change the `http_proxy` environment
  variable whenever you're on the move.


## Supported Platforms
cpcache runs on all platforms supported by Erlang, which includes x86_64 and most ARM platforms. This also means that cpcache does run on a Raspberry Pi, but you may find that cpcache does not work flawlessly on such low-end devices due to the high CPU requirements of multiple concurrent up- and downloads. Only x86_64 clients are supported by cpcache, which means that while cpcache can be installed on an ARM device, it cannot serve files to clients which run anything other than the official Arch Linux distribution.


## Installation
A package for Arch Linux is available on [AUR](https://aur.archlinux.org/packages/cpcache-git/).
Install cpcache on your server. Then, start and enable the cpcache service:
```
systemctl start cpcache.service
systemctl enable cpcache.service
```
Set the new mirror in `/etc/pacman.d/mirrorlist` on all clients. For instance, if the server running
cpcache can be reached via `alarm.local`, add the following to the beginning of the mirrorlist file:
```bash
Server = http://alarm.local:7070/$repo/os/$arch
```

## Configuration

cpcache expects a configuration file in `/etc/cpcache/cpcache.toml`. You can copy the example
configuration file from `conf/cpcache.toml` to `/etc/cpcache/cpcache.toml` and adapt it as required.


## Setup with NGINX

In case you want to use NGINX as reverse proxy, keep in mind that it uses caching by default, which
will cause timeouts in pacman since downloads then require a few seconds to start. Use
`proxy_buffering off;` to prevent this.
Here's an example config that can be used for NGINX:

```NGINX
server {
    server_name archlinux.myhost.org;
    listen [::]:80;
    listen 80;

    location ~ ^/(core|extra|community|multilib)/ {
        proxy_pass http://127.0.0.1:7070;
        proxy_buffering off;
        proxy_set_header Host $host;
        proxy_set_header X-Real-IP $remote_addr;
    }
}
```

## Setting pacman cache to a tmpfs

In case you want to avoid storing packages redundantly (i.e., both on the client and on the server running `cpcache`),
you can set the `CacheDir` in your pacman.conf to a subdirectory of `/tmp`.
`/tmp` is set to a [tmpfs](https://wiki.archlinux.org/index.php/tmpfs) by default, meaning the package cache
will be cleared when shutting down.

Simply edit your `/etc/pacman.conf` and adapt the `CacheDir` setting. For instance:

```bash
CacheDir = /tmp/pacman_cache
```

Notice that the directory `/tmp/pacman_cache` does not exist yet, and even if you were to create it, it would not
survive a reboot. Pacman will therefore emit a warning:

```
warning: no /tmp/pacman_cache/ cache exists, creating...
```

and create the directory for you. You can safely ignore this warning. Alternatively, if you prefer not to have pacman emit
this warning, you might consider adapting your `/etc/fstab` to create a second tmpfs on `/var/cache/pacman/pkg`.

# Cleaning the package cache

`paccache` from [pacman-contrib](https://www.archlinux.org/packages/?name=pacman-contrib) can be used to purge old packages. For instance, if you use the default directory for storing your packages (`/var/cache/cpcache`), the following will delete all packages except for the three most recent versions:

```bash
for cache_dir in /var/cache/cpcache/pkg/{community,core,extra,testing,multilib}/os/x86_64/; do
  paccache -k3 -c $cache_dir
done
```

## Build

Using the PKGBUILD from AUR is probably the easiest way to get cpcache up and running. But If you want to
build cpcache on your own machine, you can do so by either using Docker, or by installing Elixir
and running cpcache with Elixir's build tool, mix.

### Docker

    cd docker
    docker-compose up

Notice that all downloaded files will then be stored inside the container, so if you're using Docker
for more than just testing purposes, consider running the docker container with
[bind-mounts](https://docs.docker.com/storage/bind-mounts/) or [volumes](https://docs.docker.com/storage/volumes/).

### Mix

Install the following requirements first:

    # pacman -S git elixir sudo

Set up the cpcache user with all required directories and permissions:

    # useradd -r -s /bin/bash -m -d /var/lib/cpcache cpcache
    # mkdir -p /var/cache/cpcache/pkg/{core,extra,multilib,testing,community}/os/x86_64
    # mkdir -p /var/cache/cpcache/state
    # mkdir /etc/cpcache
    # chown -R cpcache:cpcache "/var/cache/cpcache"
    
Clone the repository and fetch all dependencies:

    # sudo -u cpcache -i
    $ git clone https://github.com/nroi/cpcache
    $ mix local.hex --force
    $ mix local.rebar --force
    $ cd cpcache
    $ mix deps.get

`cpcache` requires a config file in `/etc/cpcache`:

    # cp /var/lib/cpcache/cpcache/conf/cpcache.toml  /etc/cpcache/
    
Finally, you can run `cpcache` as its own user (i.e., run `sudo -u cpcache -i` before running this command):

    $ iex -S mix
