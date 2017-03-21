# PayDayLoan

[![Build Status](https://travis-ci.org/simplifi/pay_day_loan.svg?branch=master)](https://travis-ci.org/simplifi/pay_day_loan)
[![Coverage Status](https://coveralls.io/repos/github/simplifi/pay_day_loan/badge.svg)](https://coveralls.io/github/simplifi/pay_day_loan)
[![Hex.pm version](https://img.shields.io/hexpm/v/pay_day_loan.svg?style=flat-square)](https://hex.pm/packages/pay_day_loan)
[![Hex.pm downloads](https://img.shields.io/hexpm/dt/pay_day_loan.svg?style=flat-square)](https://hex.pm/packages/pay_day_loan)
[![License](https://img.shields.io/hexpm/l/pay_day_loan.svg?style=flat-square)](https://hex.pm/packages/pay_day_loan)
[![API Docs](https://img.shields.io/badge/api-docs-yellow.svg?style=flat)](http://hexdocs.pm/pay_day_loan/)

Fast cache now!

This project provides a framework for building on-demand caching in Elixir. 
It provides a synchronous API to a cache that is loaded asynchronously.
The cache itself may be backed in any way that you choose, though the default
is to use an ETS table backend that has several built-in features for managing
the mapping of keys to process ids (e.g., a process registry).  You have the
option of implementing your own backend using Redis, mnesia, a single process,
etc.

PDL is designed for low-latency access to cache elements after they
are initially loaded and gives you a framework to minimize load time
by performing batch loads.  This works very well with data streaming
applications that have multiple workers processing events in parallel
and are sharing cache state across workers.

Think of PDL as a cache "frontend".  In a typical application, we may want to
load data from a database and cache it for fast lookup later.  PDL provides
a "frontend" so that `MyCache.get(some_id)` will automatically make sure that
the data corresponding to `some_id` is loaded into the cache and will return
the value once it is available (or time out if the load takes too long).  It
batches the loading of data so that you can take advantage of, e.g., database
queries that fetch multiple records in one call.

The actual storage of the data is done by a cache "backend".  PDL provides a
default backend via `PayDayLoan.EtsBackend` that is quite flexible.  You can,
however, implement your own backend using the `PayDayLoan.Backend` behaviour.
This is useful for using an external service (e.g., Redis) as a cache backend.
See the examples below.

**NOTE** As of 0.3.0, any `_pid` functions (e.g., `PayDayLoan.get_pid/2`) will
emit a warning message.  These functions are deprecated and will be removed in
a future release.  `get_pid` is replaced with `get`, `peek_pid` is replaced
with `peek`, and `with_pid` is replaced with `with_value`.

## Key ideas

* Presents a synchronous API for asynchronous cache loading
* The cache consists of key-value pairs
* Provides a default backend for storing values in an ETS table but allows
  arbitrary backend implementations
* Tries very hard not to use process messaging in the main lookup API
  because that can be a bottleneck.  Uses ETS tables for state management.
* Encourages bulk queries for cache loading.
  
## Example usage: Default backend

``` elixir
# cache wrapper module - this wraps the PDL functions so that they
#   make sense within the context of your application
defmodule MyCache do
  # defines MyCache.pay_day_loan/0 (and alias pdl/0),
  #    which is set up with defaults and the supplied callback module
  use PayDayLoan, callback_module: MyCacheLoader

  # optionally pass in other arguments to override defaults, e.g.,
  #   use PayDayLoan, callback_module: MyCacheLoader, batch_size: 100
  
  # also defines pass-through functions for the PayDayLoan module -
  #  e.g., `MyCache.get(key)` is a pass-through to
  #   `MyCache.get(MyCache.pdl(), key)`
end

# cache loader callback module - this will, for example, execute database
#   queries and turn the results into cache elements (e.g., Agent or
#   GenServer processes)
defmodule MyCacheLoader do
  @behaviour PayDayLoan.Loader
 
  def key_exists?(key) do
    # should return true if the key exists -
    #   e.g., if "SELECT count(1) FROM some_table WHERE id = #{key}" returns > 0
  end

  def bulk_load(keys) do
    # code to look up records for keys in database (or whatever)
    #  should return a list of tuples of the format
    #  [{key, load_datum}]
  end
  
  def new(key, load_datum) do
    # note these are three separate examples - your callback will not do
    #   all three

    # if we are using processes:
    Agent.start_link(fn -> load_datum end)

    # if we want to store a callback:
    {:ok, fn -> {:ok, load_datum} end}

    # if we want to store the bare value
    {:ok, load_datum}
  end
  
  def refresh(existing_value, key, load_datum) do
    # note these are three separate examples - your callback will not do
    #   all three

    # if we are using proccesses, the existing_value is the pid of the
    #   already-started process
    pid = existing_value
    Agent.update(pid, fn(_cached_datum) -> load_datum end)
    # we need to return the pid back
    {:ok, pid}

    # or we could stop the existing pid and replace it with a new one
    Agent.stop(pid)
    Agent.start_link(fn -> load_datum end)

    # or if we stored a callback
    {:ok, cached_datum} = existing_value.()
    Logger.info("Replacing #{inspect cached_datum} with #{inspect load_datum}")
    {:ok, fn -> {:ok, load_datum} end}

    # or to store the new datum as a bare value
    {:ok, load_datum}
  end
end

# Add PDL to your existing supervision tree so that everything initializes properly
defmodule MyOTPApp do
  use Application 

  # existing Application.start callback
  def start(_type, _args) do
    my_supervisor_children = [
      # ... existing children specs
      PayDayLoan.supervisor_specification(MyCache.pdl)
    ]
    
    # for example
    Supervisor.start_link(my_supervisor_children, supervisor_opts)
  end
end

# synchronous API - behind the scenes will add the key (1) to the
#   load state table and the asynchronous loader will include that
#   in its next load cycle - this call does not return until either
#   the cache is loaded (via new above) or the request times out
{:ok, value} = MyCache.get(1)
```

## Example usage: Process backend (e.g., Redis connection)

``` elixir
# cache wrapper module - this wraps the PDL functions so that they
#   make sense within the context of your application
defmodule MyCache do
  # same as above but we specify a `backend` module and disable the
  #  cache monitor, we also specify a `backend_payload` so that we can
  #  specify a unique identifier for the backend process 
  use(
    PayDayLoan,
    callback_module: MyCacheLoader,
    backend: MyCacheBackend,
    backend_payload: :my_cache,
    cache_monitor: false # we won't be storing pids
  )
end

# same ideas as above but the new/refresh callbacks are different
defmodule MyCacheLoader do
  @behaviour PayDayLoan.Loader
 
  def key_exists?(key) do
    # should return true if the key exists -
    #   e.g., if "SELECT count(1) FROM some_table WHERE id = #{key}" returns > 0
  end

  def bulk_load(keys) do
    # code to look up records for keys in database (or whatever)
    #  should return a list of tuples of the format
    #  [{key, load_datum}]
  end
  
  def new(key, load_datum) do
    # we could modify the data here, but we are just going to store it raw
    {:ok, load_datum}
  end
  
  def refresh(_existing_value, key, load_datum) do
    # we could merge the existing value and the load_datum or we could modify
    #  before we store, but we're just going to replace
    {:ok, load_datum}
  end
end

# backend behaviour implementation
defmodule MyCacheBackend do
  @behaviour PayDayLoan.Backend

  # this shows an example of how we might use a single process backend, using
  # Redis is very similar - the process would be Redis connection and the
  # various callbacks would use Redis commands

  def start_link(name), do: Agent.start_link(fn -> %{} end, name: __name)

  # nothing to do for setup
  def setup(_pdl), do: :ok

  # this would be a little more involved with redis - you could use the KEYS
  #   command and then MGET but with a large cache, that approach is not
  #   advised.  SCAN can be used with larger caches.
  def reduce(pdl, acc0, reducer) do
    Agent.get(pdl.backend_payload, fn(m) -> Enum.reduce(m, acc0, reducer) end)
  end

  # with redis this could be a call to DBSIZE
  def size(pdl), do: Agent.get(pdl.backend_payload, &Map.size/1) 

  # with redis this could be a call to the KEYS command
  def keys(pdl), do: Agent.get(pdl.backend_payload, &Map.keys/1)

  # see comments on the reduce command
  def values(pdl), do: Agent.get(pdl.backend_payload, &Map.values/1)

  # this should be a simple GET command in redis
  def get(pdl, key) do
    case Agent.get(pdl.backend_payload, fn(m) -> Map.get(m, key) end) do
      nil -> {:error, :not_found}
      v -> {:ok, v}
    end
  end

  # with redis you could use SET here
  def put(pdl, key, val) do
    Agent.update(pdl.backend_payload, fn(m) -> Map.put(m, key, "V#{val}") end)
  end

  # corresponds to redis DEL
  def delete(pdl, key) do
    Agent.update(pdl.backend_payload, fn(m) -> Map.delete(m, key) end)
  end
end

# Add PDL to your existing supervision tree so that everything initializes properly
defmodule MyOTPApp do
  use Application 

  # existing Application.start callback
  def start(_type, _args) do
    my_supervisor_children = [
      # start the backend with the payload as its name
      worker(MyCacheBackend, [MyCache.pdl().backend_payload]),
      # ... existing children specs
      PayDayLoan.supervisor_specification(MyCache.pdl)
    ]
    
    # for example
    Supervisor.start_link(my_supervisor_children, supervisor_opts)
  end
end

# synchronous API - behind the scenes will add the key (1) to the
#   load state table and the asynchronous loader will include that
#   in its next load cycle - this call does not return until either
#   the cache is loaded (via new above) or the request times out
{:ok, value} = MyCache.get(1)
```

## Development & Contributing

The usual Elixir and github contribution workflows apply.  Pull requests are welcome!

```bash
mix deps.get
mix compile
mix test
```

## License

See [LICENSE.txt](LICENSE.txt)
