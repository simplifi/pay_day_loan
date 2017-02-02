defmodule PayDayLoan.LoadWorker do
  @moduledoc """
  Process to load requested keys into PDL cache.

  Whenever this process receives a ping, it attempts to load a batch
  of keys.  Requested keys are ones returned by a call to
  `LoadState.requested_keys`.

  Pings should happen automatically via the PDL API.  To force a
  ping manually, call `GenServer.cast(pdl.load_worker, :ping)`.
  """

  require Logger

  alias PayDayLoan.LoadState
  alias PayDayLoan.CacheStateManager
  alias PayDayLoan.KeyCache

  # how long to wait (msec) after startup before we do the initial load
  @startup_dwell 10

  use GenServer

  @doc "Start in a supervision tree"
  @spec start_link(PayDayLoan.t, GenServer.options) :: GenServer.on_start
  def start_link(init_state = %PayDayLoan{}, gen_server_opts \\ []) do
    GenServer.start_link(__MODULE__, [init_state], gen_server_opts)
  end

  @doc false
  @spec start(PayDayLoan.t, GenServer.options) :: GenServer.on_start
  def start(init_state = %PayDayLoan{}, gen_server_opts \\ []) do
    GenServer.start(__MODULE__, [init_state], gen_server_opts)
  end

  def init([pdl]) do
    Process.send_after(self, :ping, @startup_dwell)
    {:ok, pdl}
  end

  def handle_cast(:ping, pdl) do
    :ok = do_load(pdl, LoadState.any_requested?(pdl.load_state_manager))
    {:noreply, pdl}
  end

  def handle_info(:ping, pdl) do
    :ok = do_load(pdl, LoadState.any_requested?(pdl.load_state_manager))
    {:noreply, pdl}
  end

  defp do_load(_pdl, false), do: :ok
  defp do_load(pdl, true) do
    requested_keys = LoadState.requested_keys(pdl.load_state_manager)
    {batch_keys, _rest} = Enum.split(requested_keys, pdl.batch_size)
    _ = LoadState.loading(pdl.load_state_manager, batch_keys)

    load_batch(pdl, batch_keys)

    # loop until no more requested keys
    do_load(pdl, LoadState.any_requested?(pdl.load_state_manager))
  end

  defp load_batch(pdl, batch_keys) do
    # get data from the cache source (e.g., database)
    load_data = pdl.callback_module.bulk_load(batch_keys)

    # add it to the cache
    #   we need to know which keys did not get handled so that we can
    #   mark them as failed
    keys_not_loaded = load_data
    |> Enum.reduce(
      MapSet.new(batch_keys),
      fn({key, load_datum}, keys_remaining) ->
        # load
        pdl
        |> load_element(key, load_datum)
        |> on_load_or_refresh(pdl, key)

        # remove from the set of loading keys
        MapSet.delete(keys_remaining, key)
      end
    )

    # mark these keys as failed because we requested them and they did not
    #    get loaded into cache (e.g., the bulk load query did not return data)
    Enum.each(
      keys_not_loaded,
      fn(key) -> LoadState.failed(pdl.load_state_manager, key) end
    )
  end

  # either create a new element or update the existing one
  defp load_element(pdl, key, load_datum) do
    PayDayLoan.with_pid(
      pdl,
      key,
      fn(existing_pid) ->
        pdl.callback_module.refresh(existing_pid, key, load_datum)
      end,
      fn() ->
        pdl.callback_module.new(key, load_datum)
      end
    )
  end

  # update cache states
  defp on_load_or_refresh({:ok, updated_pid}, pdl, key) do
    _ = LoadState.loaded(pdl.load_state_manager, key)
    _ = KeyCache.add_to_cache(pdl.key_cache, key)
    CacheStateManager.put_pid(
      pdl.cache_state_manager,
      key,
      updated_pid)
  end
  defp on_load_or_refresh(:ignore, pdl, key) do
    # treat an :ignore the same as a failure to start
    #   - we failed to add this to cache
    on_load_or_refresh({:error, :ignore}, pdl, key)
  end
  defp on_load_or_refresh({:error, _}, pdl, key) do
    LoadState.failed(pdl.load_state_manager, key)
    # NOTE the callback should handle failures - we don't need to
    # bring down the worker because of it
    :ok
  end
end
