#!/bin/sh

ELIXIR_ERL_OPTIONS="-name cpcache@127.0.0.1 -mnesia dir '/var/cache/cpcache/mnesia'" /usr/bin/elixir create_mnesia_db.exs
