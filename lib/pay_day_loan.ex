defmodule PayDayLoan do
  @moduledoc File.read!(Path.expand("../README.md", __DIR__))

  @default_batch_size 1000
  @default_load_num_tries 10
  @default_load_wait_msec 500

  defstruct(
    cache_state_manager: nil,
    load_state_manager: nil,
    key_cache: nil,
    load_worker: nil,
    callback_module: nil,
    batch_size: nil,
    load_num_tries: nil,
    load_wait_msec: nil,
    supervisor_name: nil
  )

  @typedoc """
  Struct encapsulating a PDL cache.

  * `cache_state_manager` - ETS table id for cache state table and
     registration name for the monitoring GenServer.
  * `load_state_manager` - ETS table id for load state table.
  * `key_cache` - ETS table id for key cache table.
  * `load_worker` - Registration name for the load worker GenServer.
  * `callback_module` - Module implementing the PayDayLoan.Loader behaviour.
  * `batch_size` - Maximum number of keys to load at once. Default 1000
  * `load_num_tries` - Maximum number of times to wait for cache load.
     Default 10
  * `load_wait_msec` - Amount of time to wait between checking load state.
     Default 500
  """
  @type t :: %PayDayLoan{
    cache_state_manager: atom,
    load_state_manager: atom,
    key_cache: atom,
    load_worker: atom,
    callback_module: module,
    batch_size: pos_integer,
    load_num_tries: pos_integer,
    load_wait_msec: pos_integer,
    supervisor_name: atom
  }

  @typedoc """
  A key in the cache.

  This could be any Erlang/Elixir `term`.  In practice, for example, it may be
  an integer representing the primary key in a database table.
  """
  @type key :: term

  @typedoc """
  Datum returned by the load callback corresponding to a single key.

  For example, this could be a tuple of database column values or a struct
  encapsulating such values.  Your new and refresh loader callbacks should
  know how to ingest these values to generate new cache entry processes.
  """
  @type load_datum :: term

  @typedoc """
  Error values that may be returned from get_pid/2

  * `:not_found` - The key is not found as per the key_exists? loader callback
  * `:timed_out` - Timed out waiting for the value to load.
  * `:failed` - Either the new or refresh callback failed or returned `:ignore`.

  Note - failure state clears when the get_pid function returns.  Further
  calls to get_pid will retry a load.
  """
  @type error :: :not_found | :timed_out | :failed

  defmodule Loader do
    @moduledoc """
    Defines the PDL loader behaviour.
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
    Create a new cache element.  For example, this may call through
    to a GenServer.start_link or Supervisor.start_child.

    If a pid is returned, it will be added to the CacheStateManager's ETS table.
    """
    @callback new(key :: PayDayLoan.key, load_datum :: PayDayLoan.load_datum) ::
      {:ok, pid} | {:error, term} | :ignore

    @doc """
    Update a cache element.  Depending on your implementation, the returned
    pid may or may not be equal to the incoming pid.  That is, you could
    choose to update the state of the incoming pid or kill that pid and replace
    it with a new one.

    If a pid is returned, the CacheStateManager's ETS table is updated with that
    pid.
    """
    @callback refresh(
      existing_pid :: pid,
      key :: PayDayLoan.key,
      load_datum :: PayDayLoan.load_datum
    ) :: {:ok, pid} | {:error, term} | :ignore

    @doc """
    Should return true if a key exists in the cache's source.  This should be a
    fast-executing call - for example, with a database source -
    `SELECT count(1) FROM cache_source WHERE id = \#{key}`.

    You can stub this method to always return true if you want to effectively
    skip key caching.
    """
    @callback key_exists?(key :: PayDayLoan.key) :: boolean
  end

  alias PayDayLoan.LoadState
  alias PayDayLoan.CacheStateManager
  alias PayDayLoan.KeyCache

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

  Also defines a few pass-through convenience functions.

  * `MyCache.get_pid/1`
  * `MyCache.request_load/1`
  * `MyCache.size/0`
  * `MyCache.keys/0`
  * `MyCache.pids/0`
  * `MyCache.reduce/2`
  * `MyCache.with_pid/3`
  # `MyCache.cache/3`
  """
  defmacro __using__(opts) do
    # generates the pdl config and wrapper functions
    #   NOTE opts is a Keyword.t and may include key that
    #   a %PayDayLoan{} has

    # delegate to macro implementation module
    PayDayLoan.CacheGenerator.compile(opts)
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
  Check for cached pid, but do not request a load
  """
  @spec peek_pid(pdl :: t, key :: PayDayLoan.key)
  :: {:ok, pid} | {:error, :not_found}
  def peek_pid(pdl = %PayDayLoan{}, key) do
    CacheStateManager.get_pid(pdl.cache_state_manager, key)
  end

  @doc """
  Check load state, but do not request a load
  """
  @spec peek_load_state(pdl :: t, key) :: nil | LoadState.t
  def peek_load_state(pdl = %PayDayLoan{}, key) do
    LoadState.peek(pdl.load_state_manager, key)
  end

  @doc """
  Check load state, request load if not loaded or loading

  Does not ping the load worker - load will not happen until
  the next ping.
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
  Synchronously get the pid for a key, attempting to load it if
  it is not already loaded.
  """
  @spec get_pid(pdl :: t, key) :: {:ok, pid} | {:error, error}
  def get_pid(pdl = %PayDayLoan{}, key) do
    get_pid(pdl, key, peek_load_state(pdl, key), pdl.load_num_tries)
  end

  @doc """
  Returns the number of keys in the given cache
  """
  @spec cache_size(pdl :: t) :: non_neg_integer
  def cache_size(pdl = %PayDayLoan{}) do
    CacheStateManager.size(pdl.cache_state_manager)
  end

  @doc """
  Returns a list of all keys in the given cache
  """
  @spec keys(pdl :: t) :: [PayDayLoan.key]
  def keys(pdl = %PayDayLoan{}) do
    CacheStateManager.all_keys(pdl.cache_state_manager)
  end

  @doc """
  Returns a list of all pids in the given cache
  """
  @spec pids(pdl :: t) :: [pid]
  def pids(pdl = %PayDayLoan{}) do
    CacheStateManager.all_pids(pdl.cache_state_manager)
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
    CacheStateManager.reduce(pdl.cache_state_manager, acc0, reducer)
  end

  @doc """
  Execute a callback with a pid if it is found.

  If no pid is found, not_found_callback is executed.  By default,
  not_found_callback returns `{:error, :not_found}`.
  """
  @spec with_pid(
    t,
    PayDayLoan.key,
    ((pid) -> term),
    (() -> term)
  ) :: term
  def with_pid(
        pdl = %PayDayLoan{},
        key,
        found_callback,
        not_found_callback \\ fn -> {:error, :not_found} end
      ) do
    case peek_pid(pdl, key) do
      {:ok, pid} -> found_callback.(pid)
      {:error, :not_found} -> not_found_callback.()
    end
  end

  @doc """
  Manually add a single key/pid to the cache.  Fails if the key is
  already in cache with a different pid.
  """
  @spec cache(t, key, pid) :: :ok | {:error, pid}
  def cache(pdl = %PayDayLoan{}, key, pid) do
    with_pid(
      pdl,
      key,
      fn
        # found with the same pid
        (^pid) -> :ok
        # found with a different pid
        (other_pid) -> {:error, other_pid}
      end,
      fn() ->
        # not found
        _ = LoadState.loaded(pdl.load_state_manager, key)
        _ = KeyCache.add_to_cache(pdl.key_cache, key)
        CacheStateManager.put_pid(pdl.cache_state_manager, key, pid)
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
    :ok = CacheStateManager.delete_key(pdl.cache_state_manager, key)
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
      cache_state_manager: String.to_atom(name <> "_cache_state_manager"),
      load_state_manager:  String.to_atom(name <> "_load_state_manager"),
      key_cache:           String.to_atom(name <> "_key_cache"),
      load_worker:         String.to_atom(name <> "_load_worker"),
      supervisor_name:     String.to_atom(name <> "_supervisor"),
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
  # main get_pid implementatino
  #
  # this is the meat of what happens when we request a pid
  #
  # get_pid/4 is a try / wait / retry recursive function where each iteration
  # depends on the load state of the requested key (e.g., unknown, requested,
  # loading, loaded, or failed)
  #
  # ideally most of the time we want to hit the "loaded" path because we're
  # fetching an element that is already in cache

  # if we were unable to load this key, remove it from the
  #   key cache
  defp get_pid(pdl, key, _load_state, 0) do
    KeyCache.remove(pdl.key_cache, key)
    {:error, :timed_out}
  end
  # if we're already loaded, we just have to grab the pid
  #    this is hopefully the most common path
  defp get_pid(pdl, key, :loaded, try_num) do
    case peek_pid(pdl, key) do
      # if the pid died, we should remove it from the load state
      #   cache and try again
      {:error, :not_found} ->
        :ok = LoadState.unload(pdl.load_state_manager, key)
        get_pid(pdl, key, peek_load_state(pdl, key), try_num - 1)
      {:ok, pid} -> {:ok, pid}
    end
  end
  # if the key is loading, just dwell and try again
  defp get_pid(pdl, key, :loading, try_num) do
    :timer.sleep(pdl.load_wait_msec)
    get_pid(pdl, key, peek_load_state(pdl, key), try_num - 1)
  end
  # if the key has been requested but isn't loading,
  # ping the load worker to make sure it knows it has
  # work to do and then dwell and try again
  defp get_pid(pdl, key, :requested, try_num) do
    GenServer.cast(pdl.load_worker, :ping)
    # rest is the same as :loading (don't double decrement try_num)
    get_pid(pdl, key, :loading, try_num)
  end
  # cache load failed
  # return an error and clear the failure so that we can try again
  defp get_pid(pdl, key, :failed, _try_num) do
    LoadState.unload(pdl.load_state_manager, key)
    {:error, :failed}
  end
  # load state doesn't know about this key - i.e.,
  # it has not been requested (at least since the last time
  # it cached out)
  defp get_pid(pdl, key, nil, try_num) do
    # check if the key even exists in the cache source
    if KeyCache.exist?(pdl.key_cache, pdl.callback_module, key) do
      # we just need to request a load and wait
      request_load(pdl, key)
      GenServer.cast(pdl.load_worker, :ping)
      :timer.sleep(pdl.load_wait_msec)
      get_pid(pdl, key, peek_load_state(pdl, key), try_num - 1)
    else
      # if the key doesn't exist in cache source, we can immediately return
      # :not_found
      {:error, :not_found}
    end
  end
end
