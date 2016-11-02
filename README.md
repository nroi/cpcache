# cpc

cpc is a central pacman cache. It provides cached results with little
configuration. Unlike other caching solutions, cpc will not result in 404
responses that are meant to be ignored.

## How it works

For each incoming GET request, cpc checks if it can serve the request from
cache. If so, the file sent to the client while it is being read from the local
filesystem. Otherwise, the file is sent while it is being downloaded from an
ordinary pacman mirror.
In either case, the client will get an immediate response. Files need not be
downloaded from server or read from the filesystem entirely before a response is
sent to the client.
No caching is done for database files. cpc will sent a redirect response
instead.

## Centralized vs. Distributed
Each have their advantages and disadvantages, but since I already have a device
running 24/7 inside my LAN, I prefer a centralized solution for the following
reasons:
* Files download once are always available, not only when the machine that
  downloaded it first happens to be online.
* Without decentralized caching, files are still stored redundantly, inside the
  local caches of all machines. With a centralized cache, you can just set
  pacman's CacheDir to /tmp and, if you want to downgrade, get the older version
  from the central cache.
* Decentralized caches are useless if the same file is downloaded by multiple
  machines at once. With cpc, files are guaranteed to be downloaded not more
  than once. Suppose two machines request the same file at roughly (or exactly)
  the same time. What happens is that cpc starts with the first download
  request, waits until the content-length is known (i.e., until the mirror has
  replied with the header), and creates a file where the package will be
  downloaded to. Before the download has completed, the second request can be
  processed. It will then get what has already been received from the local file
  system.

## Configuration

Set the path of the local cache as well as the URI for the remote mirror in
config/config.exs, for instance:

```elixir
config :http_relay,
  root: "/path/to/cpc/cache",
  url:  "http://fooo.biz/archlinux"
```

## Installation
TODO publish on AUR
