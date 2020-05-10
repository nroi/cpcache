# cpcache

***cpcache has a successor: [flexo](https://github.com/nroi/flexo). Flexo is much more lightweight than cpcache, so please try it out. I will focus my efforts on flexo, so please don't expect any new functionality to be added to cpcache.***

cpcache is a central cache for pacman, the package manager of Arch Linux. It requires little
configuration, does not bother you with 404 errors and it allows you to utilize the full bandwidth
even as multiple clients download the same file at the same time.


## How it works

cpcache is an HTTP server that sits between pacman and the remote mirror.
To serve HTTP GET requests, it either fetches the file from the local filesystem (using sendfile), or,
if the file is not locally available, it establishes a connection to the remote mirror and downloads it from there.
In this case, the file will be stored to the local filesystem and simultaneously streamed to the requesting client.
This means the download will take just as long as it would have taken without cpcache, with the added bonus that
subsequent HTTP requests for this file can henceforth be served from the local filesystem.

cpcache is entirely transparent to pacman: Nothing that concerns pacman needs configuration changes (except for changing
the mirror, of course). No additional latency is introduced, downloads will start immediately regardless of
whether they are served from a remote mirror or the local filesystem.

For database files, no caching is done. cpcache will send a redirect response instead.

## Example use cases
Some examples where you might find cpcache useful:
- You have more than one device in your LAN that runs ArchLinux. Installing cpcache on the device that runs most often and changing the pacman mirror on all other devices allows you to download cached packages with whatever speed your LAN provides.
- You have more than one ArchLinux system running on one physical machine (e.g. Docker, QEMU, …). Installing cpcache on the host and changing the mirror on each client allows your clients to fetch cached packages almost instantaneously.  

## Comparison with other shared pacman caches
Most importantly, cpcache allows you to share bandwidth when multiple clients are downloading the same
file at the same time. For instance, suppose a second client requests a file that has been
downloaded to 30% by the first client. The second client will obtain at least 30% of the file from the cache.
Once the cache has been exhausted, we have two clients that require data from the remote mirror. That does not mean that bandwidth is split between the two clients: Instead, we continue maintain only one connection to the remote mirror.
Therefore, both clients continue to download the uncached part of the file with the full speed provided by your ISP.

Let's outline a few more differences by comparing cpcache with the different caching methods listed in the 
[wiki](https://wiki.archlinux.org/index.php?title=Pacman/Tips_and_tricks&redirect=no#Network_shared_pacman_cache):
* Read-only cache using a web server such as darkhttp:
  This is messy since it will return lots of 404s. With cpcache, uncached packages will be downloaded as
  if you were downloading them directly from the remote mirror, while also storing them in the cache to
  make them available for subsequent requests.
* Read-write caches such as [pacserve](https://wiki.archlinux.org/index.php/Pacserve) or
  [pacredir](https://github.com/eworm-de/pacredir#pacredir):
  pacserve and pacredir are distributed while cpcache is centralized.
  Distributed solutions have the advantage that they don't rely on a single machine being able to
  serve the requests from cache. However, if you have one machine that's either always running or 
  almost always running when a second machine is also running, a centralized solution will most likely
  lead to more cache hits: a package has to be downloaded only once by any arbitrary client in order to be
  available for all other clients.
* Reverse proxy cache using NGINX: Apart from the fact that cpcache can utilize the full bandwidth
  even with multiple concurrent downloads, the setup described in the wiki is quite similar to
  cpcaches approach. However, cpcache provides additional features. For instance, it obtains the
  most recent list of official mirrors and attempts to choose a fast mirror for you. This means you
  will not have to maintain a mirror list yourself.
* Proxy cache using [squid](https://wiki.archlinux.org/index.php/Package_Proxy_Cache):
  The squid approach involves changing your `http_proxy` variable, which means all HTTP GET requests
  are routed through that proxy. If the proxy is down (or just inaccessible, think of a Laptop that
  is sometimes used in your LAN and sometimes on remote locations), your HTTP GET requests will fail.
  You don't have this issue with cpcache because conceptually, cpcache is just another mirror that you
  add in your mirrorlist: if it's not available, pacman will try the next mirror.


## Installation
A package for Arch Linux is available on [AUR](https://aur.archlinux.org/packages/cpcache-git/).
Install cpcache on your server. Then, start and enable the cpcache service:
```
systemctl start cpcache.service
systemctl enable cpcache.service
```
Set the new mirror in `/etc/pacman.d/mirrorlist` on all clients. For instance, if the server running
cpcache can be reached via `myhost.local`, add the following to the beginning of the mirrorlist file:
```bash
Server = http://myhost.local:7070/$repo/os/$arch
```

## Configuration

cpcache expects a configuration file in `/etc/cpcache/cpcache.toml`. You can copy the example
configuration file from `conf/cpcache.toml` to `/etc/cpcache/cpcache.toml` and adapt it as required.

### Local repositories for pre-built AUR packages
Pacman supports custom package repositories where both the package files and the database files reside on the local filesystem.
This functionality is used by tools such as [aurto](https://github.com/alexheretic/aurto) which allow you to maintain a
repository of packages built from AUR.
cpcache can be made aware of such local repositories with the `localrepos` variable in its toml config: it will then serve all requests to this repository from the local filesystem. So if you want to make a local repository available on your LAN, you may find this setting more convenient than setting up yet another HTTP Server.

We'll describe how to use the `localrepos` setting to make packages built with aurto available on your LAN (although this setting
can be used for other local repositories as well). We assume that aurto is installed on the same device that's also
running cpcache:
1. Edit your `/etc/cpcache/cpcache.toml` to include the name of the local repository. If the file already contains a
variable named `localrepos`, change it as desired. If no variable named `localrepos` is included, add the following to the **top** of the file:

   ```toml
   localrepos = ["aurto"]
   ```

2. cpcache expects the files of the localrepo in `/var/cache/cpcache/pkg/aurto`, so let's just symlink the default directory of aurto to this directory:

   ```bash
   sudo ln -s /var/cache/pacman/aurto/ /var/cache/cpcache/pkg/ 
   ```

3. Every client needs to be acquainted with the new repository. aurto is doing this by default by adapting your `pacman.conf`
and creating a `/etc/pacman.d/aurto`, so no changes are required on the device where aurto is installed. On each client,
append the following to `pacman.conf`:

    ```
    Include = /etc/pacman.d/aurto
    ```
    and create the file `/etc/pacman.d/aurto`: it should point to the same host as defined in your mirrorlist,
    but without the trailing `/os/$arch`:
    ```
    [aurto]
    SigLevel = Optional TrustAll
    Server = http://myhost.local:7070/$repo
    ```

Verify your settings by running `pacman -Syu`: Pacman should successfully synchronize all package databases, including aurto.
You can now use aurto to build packages on the cpcache server, and then download them on all clients without having to build
them again.

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

In case you want to avoid storing packages redundantly (i.e., both on the client and on the server that runs `cpcache`),
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

## Cleaning the package cache

`paccache` from [pacman-contrib](https://www.archlinux.org/packages/?name=pacman-contrib) can be used to purge old packages. Install it if you haven't done so already:
```bash
sudo pacman -S pacman-contrib
```
Packages are stored in the directory specified by the `cache_directory` variable in `/etc/cpcache/cpcache.toml`. By default, it's `/var/cache/cpcache`. Use `paccache` to clean up the subdirectories of this directory. For instance,
the following will delete all packages except for the three most recent versions:

```bash
for cache_dir in /var/cache/cpcache/pkg/*/os/x86_64/; do
  paccache -r -k3 -c $cache_dir
done
```

## Build

Using the PKGBUILD from AUR is probably the easiest way to get cpcache up and running. But If you want to
build cpcache on your own machine, you can do so by either using Docker, or by installing Elixir
and running cpcache with Elixir's build tool, mix.

### Docker
Build the image and start the container with:

    docker-compose up

Notice that all downloaded files will then be stored inside the container, so if you're using Docker
for more than just testing purposes, consider running the docker container with
[bind-mounts](https://docs.docker.com/storage/bind-mounts/) or [volumes](https://docs.docker.com/storage/volumes/).

### Mix

Install the following requirements first:

    # pacman -S git elixir sudo

Set up the cpcache user with all required directories and permissions:

    # useradd -r -s /bin/bash -m -d /var/lib/cpcache cpcache
    # mkdir -p /var/cache/cpcache/pkg/{community,community-staging,community-testing,core,extra,gnome-unstable,kde-unstable,multilib,multilib-testing,staging,testing}/os/x86_64
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

## Supported Platforms
cpcache runs on all platforms supported by Erlang, which includes x86_64 and most ARM platforms. This also means that cpcache does run on a Raspberry Pi. Only x86_64 clients are supported by cpcache, which means that while cpcache can be installed on an ARM device, it cannot serve files to clients which run anything other than the official Arch Linux distribution.


## FAQ

### How does cpcache select the remote mirrors to download from?
After each start, cpcache fetches an up-to-date mirrorlist from https://www.archlinux.org/mirrors/status/json/.
It then filters the mirrors according to the criteria given in the `/etc/cpcache/cpcache.toml` configuration file.
This should exclude mirrors that are outdated or very unreliable. For all mirrors that
match those criteria, it runs a few latency tests and selects a mirror with good latency. The process is described
in greater detail in the configuration file.

If cpcache happens to select a mirror that turns out to be slow or unreliable, you might want to checkout the
`mirrors_predefined` and `mirrors_blacklist` option in the configuration file. But this is just a workaround, if cpcache
selects crappy mirrors, I consider this a bug and will appreciate it if you open an issue.
