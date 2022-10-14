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
  alias PayDayLoan.KeyCache

  # how long to wait (msec) after startup before we do the initial load
  @startup_dwell 10

  @type state :: %{
          pdl: PayDayLoan.t(),
          load_task_ref: nil | reference()
        }

  use GenServer

  @doc "Start in a supervision tree"
  @spec start_link({PayDayLoan.t(), GenServer.options()}) :: GenServer.on_start()
  def start_link({init_state = %PayDayLoan{}, gen_server_opts}) do
    GenServer.start_link(__MODULE__, [init_state], gen_server_opts)
  end

  @spec init([PayDayLoan.t()]) :: {:ok, state}
  @impl true
  def init([pdl]) do
    Process.send_after(self(), :ping, @startup_dwell)
    {:ok, %{pdl: pdl, load_task_ref: nil}}
  end

  @spec handle_cast(atom, state) :: {:noreply, state}
  @impl true
  def handle_cast(:ping, %{pdl: pdl, load_task_ref: nil} = state) do
    load_task = start_load_task(pdl)
    {:noreply, %{state | load_task_ref: load_task.ref}}
  end

  def handle_cast(:ping, %{pdl: _pdl, load_task_ref: ref} = state) when is_reference(ref) do
    {:noreply, state}
  end

  @spec handle_info(atom, state) :: {:noreply, state}
  @impl true
  def handle_info(:ping, %{pdl: pdl, load_task_ref: nil} = state) do
    load_task = start_load_task(pdl)
    {:noreply, %{state | load_task_ref: load_task.ref}}
  end

  def handle_info(:ping, %{pdl: _pdl, load_task_ref: ref} = state) when is_reference(ref) do
    {:noreply, state}
  end

  @spec handle_info(tuple, state) :: {:noreply, state}
  @impl true
  def handle_info({ref, :ok}, state) do
    Process.demonitor(ref, [:flush])
    {:noreply, %{state | load_task_ref: nil}}
  end

  def handle_info({:DOWN, _ref, :process, _pid, _reason}, %{pdl: pdl} = state) do
    # The loader process died, so reset the status of any keys that were in the :loading
    # or :request_loading states to unloaded.

    pending_keys =
      LoadState.loading_keys(pdl.load_state_manager) ++
        LoadState.reload_loading_keys(pdl.load_state_manager)

    LoadState.unload(pdl.load_state_manager, pending_keys)

    {:noreply, %{state | load_task_ref: nil}}
  end

  @spec start_load_task(PayDayLoan.t()) :: Task.t()
  defp start_load_task(pdl) do
    Task.Supervisor.async_nolink(pdl.load_task_supervisor, fn -> do_load(pdl, false) end)
  end

  defp do_load(_pdl, true), do: :ok

  defp do_load(pdl, false) do
    requested_keys = LoadState.requested_keys(pdl.load_state_manager, pdl.batch_size)
    _ = LoadState.loading(pdl.load_state_manager, requested_keys)

    reload_keys =
      LoadState.reload_keys(
        pdl.load_state_manager,
        pdl.batch_size - length(requested_keys)
      )

    _ = LoadState.reload_loading(pdl.load_state_manager, reload_keys)

    load_batch(pdl, requested_keys ++ reload_keys)

    # loop until no more requested keys
    finished? = Enum.empty?(requested_keys) && Enum.empty?(reload_keys)
    do_load(pdl, finished?)
  end

  defp load_batch(_pdl, []) do
    :ok
  end

  defp load_batch(pdl, batch_keys) do
    # get data from the cache source (e.g., database)
    load_data = pdl.callback_module.bulk_load(batch_keys)

    # add it to the cache
    #   we need to know which keys did not get handled so that we can
    #   mark them as failed
    keys_not_loaded =
      load_data
      |> Enum.reduce(
        MapSet.new(batch_keys),
        fn {key, load_datum}, keys_remaining ->
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
      fn key -> LoadState.failed(pdl.load_state_manager, key) end
    )
  end

  # either create a new element or update the existing one
  defp load_element(pdl, key, load_datum) do
    PayDayLoan.with_value(
      pdl,
      key,
      fn existing_value ->
        pdl.callback_module.refresh(existing_value, key, load_datum)
      end,
      fn ->
        pdl.callback_module.new(key, load_datum)
      end
    )
  end

  # update cache states
  defp on_load_or_refresh({:ok, value}, pdl, key) do
    _ = LoadState.loaded(pdl.load_state_manager, key)
    _ = KeyCache.add_to_cache(pdl.key_cache, key)
    pdl.backend.put(pdl, key, value)
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
