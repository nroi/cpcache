# Persistent Connections

conn_pool (gen_server): Stores the current hackney connections in its state.

client_request: Instead of creating the connection itself, send a message to conn_pool to
request a connection to the given host. conn_pool will then look if there is an existing
connection that can be re-used and if so, return it. Otherwise, create a new connection
to the given host and return it.

state of the conn_pool:

```Elixir
[{host, conn_ref, state}]
```

where `state` is `:active` or `:inactive`.

When a `client_request` does not need a conn_ref anymore, it sends a message to the `conn_pool`
to inform it. the `conn_pool` will change the `conn_ref` state to `:inactive` and start
a timer. If a new request for this host arrives within (say) 5 seconds, the `conn_ref` is set
to active and returned. If no new request of this host arrives within 5 seconds, the `conn_ref`
is removed from the `conn_pool` state.

## generalized

the gen_server starts with an empty list, waiting for requests. When someone
requests `A`, the gen_server executes a function `(A) -> B` and then returns `B`
to the requester.

`B` refers to a resource that should be closed once it is not required anymore.
So the gen_server waits for the original requester send him a message as soon as `B`
is not required anymore. Also, if the requester crashes, the gen_server should be
notified to set the resource to the `:inactive` state. If this resource is not requested
by anyone in a given time interval, it will be released.

If a client requests the resource resulting from `A`, the gen_server will first check if 
if already has a resource that resultet from `A` which is currently not being used.
If that is the case, no new `B` will be created from `A`, instead, the existing `B` associated
with the given `A` will be returned.
