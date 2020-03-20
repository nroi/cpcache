#!/bin/bash

mkdir -p /var/cache/cpcache/pkg/{community,community-staging,community-testing,core,extra,gnome-unstable,kde-unstable,multilib,multilib-testing,staging,testing}/os/x86_64
mkdir -p /var/cache/cpcache/state

/var/lib/cpcache/bin/cpcache start

