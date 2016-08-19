# PayDayLoan

[![Build Status](https://travis-ci.org/simplifi/pay_day_loan.svg?branch=master)](https://travis-ci.org/simplifi/pay_day_loan)
[![Hex.pm version](https://img.shields.io/hexpm/v/pay_day_loan.svg?style=flat-square)](https://hex.pm/packages/pay_day_loan)
[![Hex.pm downloads](https://img.shields.io/hexpm/dt/pay_day_loan.svg?style=flat-square)](https://hex.pm/packages/pay_day_loan)
[![License](https://img.shields.io/hexpm/l/pay_day_loan.svg?style=flat-square)](https://hex.pm/packages/pay_day_loan)
[![API Docs](https://img.shields.io/badge/api-docs-yellow.svg?style=flat)](http://hexdocs.pm/pay_day_loan/)

Fast cache now!

This project provides a framework for building on-demand caching in Elixir. 
It provides a synchronous API to a cache that is loaded asynchronously.
Each cache element is assumed to be a process and PDL is mainly concerned with
maintaining the mapping from key to pid.  Pids are automatically removed from
cache when the corresponding process dies.

PDL is designed for low-latency access to cache elements after they
are initially loaded and gives you a framework to minimize load time
by performing batch loads.  This works very well with data streaming
applications that have multiple workers processing events in parallel
and are sharing cache state across workers.

## Key ideas

* Presents a synchronous API for asynchronous cache loading
* Cache is key-value pairs, where key could be any erlang term and
  value is intended to be an Erlang pid for a process encapsulating the
  cached data.
* Tries very hard not to use process messaging in the main lookup API
  because that can be a bottleneck.  Uses ETS tables for state management.
* Encourages bulk queries for cache loading.
  
## Recommended Usage

Example:

``` elixir
# cache wrapper module - this wraps the PDL functions so that they
#   make sense within the context of your application
defmodule MyCache do
  # defines MyCache.pay_day_loan/0 (and alias pdl/0),
  #    which is set up with defaults and the supplied callback module
  use PayDayLoan, callback_module: MyCacheLoader

  # optionally pass in other arguments to override defaults, e.g.,
  #   use PayDayLoan, callback_module: MyCacheLoader, batch_size: 100
  
  # also defined: get_pid/1, size/0, request_load/1
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
    # should create some kind of process for key with load datum that was
    #   fetched above
    #  -- considering making some 'utility' plugins for this, though any pid works
    # should return something like a GenServer.on_start
  end
  
  def refresh(pid, key, load_datum) do
    # updates the info stored in pid for key with new load_datum
    #   implementation is up to the user here - could return the same pid
    #   or a different pid with a replacement process
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
{:ok, pid} = MyCache.get_pid(1)
```

## Components

* PayDayLoan - Public API module and mixin (`use`) support
* CacheStateManager - ETS table of key to cache pid, plus monitor
  GenServer (removes cache elements on pid termination).
* LoadState - ETS table keeping track of which keys are loaded,
  loading, and requested.
* KeyCache - ETS table keeping track of which keys are known to
  exist.
* LoadWorker - GenServer that polls the LoadState table for keys to load.
* Supervisor - OTP supervisor implementation

## Development & Contributing

The usual Elixir and github contribution workflows apply.  Pull requests are welcome!

```bash
mix deps.get
mix compile
mix test
```

## License

See [LICENSE.txt](LICENSE.txt)
