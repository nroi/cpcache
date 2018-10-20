# cpcache

cpcache is a central cache for pacman, the package manager of Arch Linux. It requires little
configuration, does not bother you with 404 errors and it allows you to utilize the full bandwidth
even as multiple clients download the same file at the same time.
Combined with [clyde](https://github.com/nroi/clyde-server), it also allows you to download updated
packages in advance so that most requests can be served from cache when running `pacman -Syu`.


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
  [paccache](https://github.com/eworm-de/paccache):
  pacserve and paccache are distributed while cpcache is centralized. A distributed solution is your
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

In case you want to avoid storing packages redundantly you can set the `CacheDir` in your pacman.conf to a [tmpfs](https://wiki.archlinux.org/index.php/tmpfs). This will clear the pacakge cache when shutting down. More information about these methods can be found [here](https://github.com/nroi/cpcache/pull/4#issuecomment-431595309).

### Method 1

Add `CacheDir = tmp/pacman/pkg` in `/etc/pacman.conf`. 

NOTE: This may produce warnings when the directory does not exist.

### Method 2

This will create a new tmpfs instead of using `/tmp`

Add  this line to your `/etc/fstab` file:
```
tmpfs  /var/cache/pacman/pkg  tmpfs  nodev,nosuid,size=2G  0  0
```

You can customize the size of the tmpfs by modifying `size=2G`.

To mount the new tmpfs you just need to run `mount -a` **as root**. The tmpfs will be mounted automatically on every boot.
