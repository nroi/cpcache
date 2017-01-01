#!/bin/sh

ELIXIR_ERL_OPTIONS="-sname cpcache -mnesia dir '/var/cache/cpcache/mnesia'" /usr/bin/elixir create_mnesia_db.exs
