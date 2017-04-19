defmodule PayDayLoan do
  @moduledoc File.read!(Path.expand("../README.md", __DIR__))

  require Logger

  @default_batch_size 1000
  @default_load_num_tries 10
  @default_load_wait_msec 500

  defstruct(
    backend_payload: nil,
    load_state_manager: nil,
    cache_monitor: nil,
    backend: PayDayLoan.EtsBackend,
    key_cache: nil,
    load_worker: nil,
    callback_module: nil,
    batch_size: nil,
    load_num_tries: nil,
    load_wait_msec: nil,
    supervisor_name: nil,
    event_loggers: []
  )

  @typedoc """
  A key in the cache.

  This could be any Erlang/Elixir `term`.  In practice, for example, it may be
  an integer representing the primary key in a database table.
  """
  @type key :: term

  @typedoc """
  An event that can happen on cache request.

  * `:timed_out` - Timed out while loading cache.
  * `:disappeared` - Key was marked as `:loaded` but the backend did not return
    a value
  * `:failed` - The loader failed to load a value for the key
  * `:cache_miss` - A requested value was not already cached
  * `:no_key` - The loaded says this key does not exist
  """
  @type event :: :timed_out | :disappeared | :failed | :cache_miss | :no_key

  @typedoc """
  A function that takes an `event` and a `key` and performs some logging action.
  The return value is ignored
  """
  @type event_logger :: ((event, key) -> term)

  @typedoc """
  Struct encapsulating a PDL cache.

  * `backend` - Implementation of the Backend behaviour -
    defaults to PayDayLoan.EtsBackend.
  * `backend_payload` - Arbitrary payload for the backend - defaults to the
    ETS table id for the ETS backend.
  * `load_state_manager` - ETS table id for load state table.
  * `cache_monitor` - Registration name for the monitor process, or false if
    no monitor should be started.
  * `key_cache` - ETS table id for key cache table.
  * `load_worker` - Registration name for the load worker GenServer.
  * `callback_module` - Module implementing the PayDayLoan.Loader behaviour.
  * `batch_size` - Maximum number of keys to load at once. Default 1000
  * `load_num_tries` - Maximum number of times to wait for cache load.
     Default 10
  * `load_wait_msec` - Amount of time to wait between checking load state.
     Default 500
  * `supervisor_name` - Registration name for the supervisor.
  """
  @type t :: %PayDayLoan{
    backend_payload: atom,
    load_state_manager: atom,
    cache_monitor: atom | false,
    backend: atom,
    key_cache: atom,
    load_worker: atom,
    callback_module: module,
    batch_size: pos_integer,
    load_num_tries: pos_integer,
    load_wait_msec: pos_integer,
    supervisor_name: atom,
    event_loggers: [event_logger]
  }

  @typedoc """
  Datum returned by the load callback corresponding to a single key.

  For example, this could be a tuple of database column values or a struct
  encapsulating such values.  Your new and refresh loader callbacks should
  know how to ingest these values to generate new cache entry processes.
  """
  @type load_datum :: term

  @typedoc """
  Error values that may be returned from get/2

  * `:not_found` - The key is not found as per the key_exists? loader callback
  * `:timed_out` - Timed out waiting for the value to load.
  * `:failed` - Either the new or refresh callback failed or returned `:ignore`.

  Note - failure state clears when the get function returns.  Further
  calls to get will retry a load.
  """
  @type error :: :not_found | :timed_out | :failed

  defmodule Loader do
    @moduledoc """
    Defines the PDL loader behaviour.

    The loader is responsible for fetching a batch of data (`bulk_load/1`) from
    the cache's source (e.g., a database).  For each element that is fetched,
    we check if there is an existing element in the cache backend.

    If no existing element is found for a key, we call `new/2` with the
    corresponding key and value.  This gives the loader an opportunity to alter
    what is stored in the backend from what is returned by the loader.  For
    example, we may be using a process backend and all we need to store is the
    pid.

    If an existing value is found for a key, we call `refresh/3` with the
    existing backend value, the key, and the load datum.  For example, with a
    process backend this may involve making a GenServer or Agent update call
    before returning the pid to the backend.

    The `key_exists?/1` function is a hook for the key cache.
    """

    @doc """
    Fetch values to be loaded into cache.  For example, perform
    a database lookup and return the data normalized in some form that
    your cache elements will understand.

    `new` or `refresh` will be called for each returned element as
    appropriate.

    Note that there is no requirement that each key passed in
    be represented in the output.
    """
    @callback bulk_load(keys :: [PayDayLoan.key]) ::
      [{PayDayLoan.key, PayDayLoan.load_datum}]

    @doc """
    Create a new cache element before sending it to the backend.

    For example, this may create a process and the resulting pid is what is
    actually stored in the backend, or it may simply manipulate the load datum
    before it is stored.  To store the load datum directly in the backend,
    just return `{:ok, load_datum}`.  To signal an error which will cause the
    load to fail for this key, return `{:error, <error payload>}`.
    """
    @callback new(key :: PayDayLoan.key, load_datum :: PayDayLoan.load_datum) ::
      {:ok, term} | {:error, term} | :ignore

    @doc """
    Update a cache element before storing it.

    This is called when a load occurs for a key that already has a value in
    the cache.  You can use this callback to resolve the differences or to
    update the value before sending it on to the backend.  For example, with
    a process-based cache (e.g. using `PayDayLoan.EtsBackend`), the
    `existing_value` is the backing processes pid and you may need to call
    something like `Agent.update(existing_value, key, <update function>)` and
    return `existing_value` unchanged (since the same pid will still be stored
    on the backend).

    To pass the load datum directly through to the backend, return
    `{:ok, load_datum}`.  To signal an error, return
    `{:error, <error payload>}`.  To ignore this datum, return `:ignore`.  In
    both the `:ignore` and `:error` cases, the key will not be reloaded until
    it is requested again.
    """
    @callback refresh(
      existing_value :: term,
      key :: PayDayLoan.key,
      load_datum :: PayDayLoan.load_datum
    ) :: {:ok, term} | {:error, term} | :ignore

    @doc """
    Should return true if a key exists in the cache's source.  This should be a
    fast-executing call - for example, with a database source -
    `SELECT count(1) FROM cache_source WHERE id = \#{key}`.

    You can stub this method to always return true if you want to effectively
    skip key caching.
    """
    @callback key_exists?(key :: PayDayLoan.key) :: boolean
  end

  defmodule Backend do
    @moduledoc """
    Defines the PDL backend behaviour.

    The backend is responsible for allowing us to access the cached value
    for a given key.  PayDayLoan's `EtsBackend` module is used by default, and
    is built with a process cache in mind.  You could use the `Backend`
    behaviour to implement, for example, a Redis or mnesia backend.
    """

    @doc """
    Called during supervisor initialization - use this callback to initialize
    your backend if needed.  Must return `:ok`.
    """
    @callback setup(PayDayLoan.t) :: :ok

    @doc """
    Should execute a reduce operation over the key/value pairs in the cache.

    The reducer function should take arguments in the form
    `({key, value}, accumulator)` and return the new accumulator value - i.e.,
    it should operate as `Enum.reduce/3` would when given a map.
    """
    @callback reduce(
      PayDayLoan.t,
      acc0 :: term,
      reducer :: (({PayDayLoan.key, term}, term) -> term)) ::  term

    @doc """
    Should return the number of keys in the cache
    """
    @callback size(PayDayLoan.t) :: non_neg_integer

    @doc """
    Should return a list of keys in the cache
    """
    @callback keys(PayDayLoan.t) :: [PayDayLoan.key]

    @doc """
    Should return a list of values in the cache
    """
    @callback values(PayDayLoan.t) :: [term]

    @doc """
    Retrieve a value from the cache

    Should return `{:error, :not_found}` if the value is not found and
    `{:ok, value}` otherwise.
    """
    @callback get(PayDayLoan.t, PayDayLoan.key)
    :: {:ok, term} | {:error, :not_found}

    @doc """
    Insert a value into the cache

    Must return `:ok`
    """
    @callback put(PayDayLoan.t, PayDayLoan.key, term) :: :ok

    @doc """
    Delete a key from the cache

    Must return `:ok`
    """
    @callback delete(PayDayLoan.t, PayDayLoan.key) :: :ok
  end

  alias PayDayLoan.CacheGenerator
  alias PayDayLoan.KeyCache
  alias PayDayLoan.LoadState

  @doc """
  Mixin support for generating a cache.

  Example:

      defmodule MyCache do
        use PayDayLoan, callback_module: MyCacheLoader
      end

  The above would define `MyCache.pay_day_loan/0`, which returns a PDL struct
  that is configured for this cache and has callback module `MyCacheLoader`.
  Other keys of the `%PayDayLoan{}` struct can be passed in as options to
  override the defaults.

  Also defines pass-through convenience functions for every function in
  `PayDayLoan`.
  """
  defmacro __using__(opts) do
    # generates the pdl config and wrapper functions
    #   NOTE opts is a Keyword.t and may include key that
    #   a %PayDayLoan{} has

    # delegate to macro implementation module
    CacheGenerator.compile(opts)
  end

  @doc """
  Returns a supervisor specification for the given pdl
  """
  @spec supervisor_specification(pdl :: PayDayLoan.t) :: Supervisor.Spec.spec
  def supervisor_specification(pdl = %PayDayLoan{}) do
    pdl = pdl
    |> merge_defaults

    Supervisor.Spec.supervisor(
      PayDayLoan.Supervisor,
      [pdl],
      id: pdl.supervisor_name
    )
  end

  @doc """
  Check for a cached value, but do not request a load
  """
  @spec peek(t, key) :: {:ok, term} | {:error, :not_found}
  def peek(pdl = %PayDayLoan{}, key) do
    pdl.backend.get(pdl, key)
  end

  @doc """
  Check load state, but do not request a load
  """
  @spec peek_load_state(pdl :: t, key) :: nil | LoadState.t
  def peek_load_state(pdl = %PayDayLoan{}, key) do
    LoadState.peek(pdl.load_state_manager, key)
  end

  @doc """
  Returns a map of load states and the number of keys in each state

  Useful for instrumentation
  """
  @spec load_state_stats(pdl :: t) :: %{}
  def load_state_stats(pdl = %PayDayLoan{}) do
    stats = %{requested: 0, loaded: 0, loading: 0, failed: 0}
    # this is stepping over the boundary of the PDL - this function could
    # be added to the PDL library
    :ets.foldl(
      fn({_key, status}, stats_acc) ->
        Map.update(stats_acc, status, 0, fn(c) -> c + 1 end)
      end,
      stats,
      pdl.load_state_manager
    )
  end

  @doc """
  Check load state, request load if not loaded or loading

  Does not ping the load worker.  A load will not happen until
  the next ping.  Use `request_load/2` to request load and trigger a load ping.
  """
  @spec query_load_state(pdl :: t, key) :: LoadState.t
  def query_load_state(pdl = %PayDayLoan{}, key) do
    LoadState.query(pdl.load_state_manager, key)
  end

  @doc """
  Request a load of one or more keys.

  Load is asynchronous - this function returns immediately
  """
  @spec request_load(pdl :: t, key | [key]) :: :ok
  def request_load(pdl = %PayDayLoan{}, key_or_keys) do
    LoadState.request(pdl.load_state_manager, key_or_keys)
    GenServer.cast(pdl.load_worker, :ping)
    :ok
  end

  @doc """
  Synchronously get the value for a key, attempting to load it if it is not
  alraedy loaded.
  """
  @spec get(pdl :: t, key) :: {:ok, term} | {:error, error}
  def get(pdl = %PayDayLoan{}, key) do
    get(pdl, key, peek_load_state(pdl, key), pdl.load_num_tries)
  end

  @doc """
  Returns the number of keys in the given cache
  """
  @spec size(pdl :: t) :: non_neg_integer
  def size(pdl = %PayDayLoan{}) do
    pdl.backend.size(pdl)
  end

  @doc """
  Returns a list of all keys in the given cache
  """
  @spec keys(pdl :: t) :: [PayDayLoan.key]
  def keys(pdl = %PayDayLoan{}) do
    pdl.backend.keys(pdl)
  end

  @doc """
  Returns a list of all pids in the given cache
  """
  @spec pids(pdl :: t) :: [pid]
  def pids(pdl = %PayDayLoan{}) do
    values(pdl)
  end

  @doc """
  Return all of the values stored in the backend
  """
  @spec values(pdl :: t) :: [term]
  def values(pdl = %PayDayLoan{}) do
    pdl.backend.values(pdl)
  end

  @doc """
  Perform Enum.reduce/3 over all {key, pid} pairs in the given cache
  """
  @spec reduce(
    pdl :: t,
    acc0 :: term,
    reducer :: (({key, pid}, term) -> term)) :: term
  def reduce(pdl = %PayDayLoan{}, acc0, reducer)
  when is_function(reducer, 2) do
    pdl.backend.reduce(pdl, acc0, reducer)
  end

  @doc """
  Execute a callback with a value if it is found.

  If no value is found, `not_found_callback` is executed.  By default,
  the `not_found_callback` is a function that returns `{:error, :not_found}`.
  """
  @spec with_value(t, PayDayLoan.key, ((term) -> term), (() -> term)) :: term
  def with_value(
    pdl,
    key,
    found_callback,
    not_found_callback \\ fn -> {:error, :not_found} end
  ) do
    case peek(pdl, key) do
      {:ok, value} -> found_callback.(value)
      {:error, :not_found} -> not_found_callback.()
    end
  end

  @doc """
  Manually add a single key/pid to the cache.  Fails if the key is
  already in cache with a different pid.
  """
  @spec cache(t, key, pid) :: :ok | {:error, pid}
  def cache(pdl = %PayDayLoan{}, key, value) do
    with_value(
      pdl,
      key,
      fn
        # found with the same value
        (^value) -> :ok
        # found with a different pid
        (other_value) -> {:error, other_value}
      end,
      fn() ->
        # not found
        _ = LoadState.loaded(pdl.load_state_manager, key)
        _ = KeyCache.add_to_cache(pdl.key_cache, key)
        pdl.backend.put(pdl, key, value)
      end
    )
  end

  @doc """
  Remove a key without killing the underlying process.

  If you want to remove an element from cache, just kill the underlying
  process.
  """
  @spec uncache_key(t, key) :: :ok
  def uncache_key(pdl = %PayDayLoan{}, key) do
    :ok = pdl.backend.delete(pdl, key)
    :ok = LoadState.unload(pdl.load_state_manager, key)
    :ok = KeyCache.remove(pdl.key_cache, key)
  end

  # won't be calling this manually, but it needs to be public for the macro
  @doc false
  @spec merge_defaults(t) :: t
  def merge_defaults(pdl = %PayDayLoan{callback_module: callback_module})
  when not is_nil(callback_module) do
    name = callback_module_to_name_string(callback_module)

    defaults = %PayDayLoan{
      backend_payload:     String.to_atom(name <> "_backend"),
      load_state_manager:  String.to_atom(name <> "_load_state_manager"),
      cache_monitor:       String.to_atom(name <> "_cache_monitor"),
      backend:             PayDayLoan.EtsBackend,
      key_cache:           String.to_atom(name <> "_key_cache"),
      load_worker:         String.to_atom(name <> "_load_worker"),
      supervisor_name:     String.to_atom(name <> "_supervisor"),
      event_loggers:       [],
      batch_size:          @default_batch_size,
      load_num_tries:      @default_load_num_tries,
      load_wait_msec:      @default_load_wait_msec
    }

    Map.merge(defaults, pdl, &nil_merge/3)
  end

  # generates snake_case strings from ModuleNames to use as table
  # ids, etc.
  defp callback_module_to_name_string(callback_module) do
    callback_module
    |> Macro.underscore
    |> String.replace("/", "_")
  end

  # map merge with nil values - take v2 if it is not nil
  defp nil_merge(_k, v, nil), do: v
  defp nil_merge(_k, _v1, v2), do: v2

  ######################################################################
  # main get implementation
  #
  # this is the meat of what happens when we request a value
  #
  # get/4 is a try / wait / retry recursive function where each iteration
  # depends on the load state of the requested key (e.g., unknown, requested,
  # loading, loaded, or failed)
  #
  # ideally most of the time we want to hit the "loaded" path because we're
  # fetching an element that is already in cache

  # if we were unable to load this key, remove it from the
  #   key cache
  defp get(pdl, key, _load_state, 0) do
    KeyCache.remove(pdl.key_cache, key)
    event_log(pdl, :timed_out, key)
    {:error, :timed_out}
  end
  # if we're already loaded, we just have to grab the pid
  #    this is hopefully the most common path
  defp get(pdl, key, :loaded, try_num) do
    case pdl.backend.get(pdl, key) do
      # if the value was removed from the backend, we should remove it from
      # the load state and try again
      {:error, :not_found} ->
        event_log(pdl, :disappeared, key)
        :ok = LoadState.unload(pdl.load_state_manager, key)
        get(pdl, key, peek_load_state(pdl, key), try_num - 1)
      {:ok, value} -> {:ok, value}
    end
  end
  # if the key is loading, just dwell and try again
  defp get(pdl, key, :loading, try_num) do
    :timer.sleep(pdl.load_wait_msec)
    get(pdl, key, peek_load_state(pdl, key), try_num - 1)
  end
  # if the key has been requested but isn't loading,
  # ping the load worker to make sure it knows it has
  # work to do and then dwell and try again
  defp get(pdl, key, :requested, try_num) do
    GenServer.cast(pdl.load_worker, :ping)
    # rest is the same as :loading (don't double decrement try_num)
    get(pdl, key, :loading, try_num)
  end
  # cache load failed
  # return an error and clear the failure so that we can try again
  defp get(pdl, key, :failed, _try_num) do
    event_log(pdl, :failed, key)
    LoadState.unload(pdl.load_state_manager, key)
    {:error, :failed}
  end
  # load state doesn't know about this key - i.e.,
  # it has not been requested (at least since the last time
  # it cached out)
  defp get(pdl, key, nil, try_num) do
    # check if the key even exists in the cache source
    if KeyCache.exist?(pdl.key_cache, pdl.callback_module, key) do
      # we just need to request a load and wait
      event_log(pdl, :cache_miss, key)
      request_load(pdl, key)
      GenServer.cast(pdl.load_worker, :ping)
      :timer.sleep(pdl.load_wait_msec)
      get(pdl, key, peek_load_state(pdl, key), try_num - 1)
    else
      # if the key doesn't exist in cache source, we can immediately return
      event_log(pdl, :no_key, key)
      {:error, :not_found}
    end
  end

  defp event_log(pdl, event, key) do
    Enum.each(pdl.event_loggers, fn(logger) ->
      logger.(event, key)
    end)
  end
end
