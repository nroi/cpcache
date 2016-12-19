# cpcache

cpcache is a central cache for pacman, the package manager of Arch Linux. It requires little
configuration, does not bother you with 404 errors and it allows you to utilize the full bandwidth
even as multiple clients download the same file at the same time.

## Current Status
Beta. More testing is required for parallel downloads and content-ranges.

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
provided by your ISP. See
[this recording](https://up.helios.click/f/parallel-downloads.webm) for a simple demonstration.

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
  at one place. This allows you to just set pacman's `CacheDir` to `/tmp` instead of storing
  packages redundantly. Also, packages that are cached once are always available, not only if the
  machine that cached it happens to be online.
* Reverse proxy cache using NGINX: Apart from the fact that cpcache can utilize the full bandwidth
  even with multiple concurrent downloads, the setup described in the wiki is quite similar to cpc's
  approach.

# Setup with NGINX
In case you want to use NGINX as reverse proxy, keep in mind that it uses caching by default, which
will cause timeouts in pacman since downloads then requires a few seconds to start. Use
`proxy_buffering off;` to prevent this.


## Dependencies
Apart from Elixir and Erlang, cpcache requires
[inotify-tools](https://github.com/rvoicilas/inotify-tools) and paccache. paccache (not to be confused with
[paccache](https://github.com/eworm-de/paccache) mentioned above) is included with pacman, hence it
does not need to be installed if you're running Arch Linux. Otherwise, you can set the `keep` option
to `0` in `/etc/cpcache.yaml`, which will deactivate purging and therefore not require paccache.

## Limitations
The mirror configured in /etc/cpcache.yaml must use the default relative path, i.e., `$repo/os/$arch`
for x86 and `$arch/$repo` for arm.

## Configuration

cpcache expects a configuration file in `/etc/cpcache.yaml`. You can copy the example configuration file
from `conf/cpcache.yaml` to `/etc` and adapt it as required.

## Installation
A package for Arch Linux is available on [AUR](https://aur.archlinux.org/packages/cpcache-git/).
Install cpcache on your server. Then, start and enable the cpcache service:
```
systemctl start cpcache.service
systemctl enable cpcache.service
```
Set the new mirror in `/etc/pacman.d/mirrorlist` on all clients. For instance, if the server running
cpcache can be reached via `alarm.local`, at the following to the top of the mirrorlist file:
```
Server = http://alarm.local:7070/$repo/os/$arch
```
