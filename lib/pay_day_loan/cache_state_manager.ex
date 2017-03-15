defmodule PayDayLoan.CacheStateManager do
  @moduledoc """
  Keeps track of which keys are cached.

  The implementation of this has two parts:
  1. An ETS table mapping key to cache pid.
  2. A GenServer that monitors the cached pids and is responsible
     for removing pids from the ETS table when the corresponding
     process dies.

  You shouldn't need to call any of the functions in this module
  manually, but they can be useful for debugging.
  """

  use GenServer

  defmodule State do
    @moduledoc false

    defstruct(pdl: nil, monitors: %{})
    @type t :: %__MODULE__{}
  end
  alias PayDayLoan.CacheStateManager.State

  # used by the supervisor
  @doc false
  @spec start_link(PayDayLoan.t, GenServer.options) :: GenServer.on_start
  def start_link(pdl = %PayDayLoan{}, gen_server_opts \\ []) do
    GenServer.start_link(__MODULE__, [pdl], gen_server_opts)
  end

  # this should get called by the supervisor during startup
  @doc false
  @spec create_table(atom) :: :ok
  def create_table(ets_table_id) do
    _ = :ets.new(
      ets_table_id,
      [:public, :named_table, {:read_concurrency, true}]
    )
    :ok
  end

  @doc """
  Perform Enum.reduce on the ETS table
  """
  @spec reduce(atom, term, (({PayDayLoan.key, pid}, term) -> term)) :: term
  def reduce(ets_table_id, acc0, reducer)
  when is_function(reducer, 2) do
    :ets.foldl(
      fn({k, v}, acc) ->
        case resolve_value(v, k, ets_table_id) do
          {:ok, resolved_v} -> reducer.({k, resolved_v}, acc)
          {:error, :not_found} -> acc
        end
      end,
      acc0,
      ets_table_id
    )
  end

  @doc """
  Returns the number of cached keys
  """
  @spec size(atom) :: non_neg_integer
  def size(ets_table_id) do
    :ets.info(ets_table_id, :size)
  end

  @doc """
  Returns a list of all cached keys
  """
  @spec all_keys(atom) :: [PayDayLoan.key]
  def all_keys(ets_table_id) do
    reduce(ets_table_id, [], fn({k, _pid}, acc) -> [k | acc] end)
  end

  @doc """
  Returns a list of all cached values
  """
  @spec all_values(atom) :: [term]
  def all_values(ets_table_id) do
    reduce(ets_table_id, [], fn({_k, v}, acc) -> [v | acc] end)
  end

  @doc """
  Get the pid corresponding to the given key

  If the process is not alive, deletes the entry and returns
  `{:error, :not_found}`.
  """
  @spec get_pid(atom, PayDayLoan.key) :: {:ok, pid} | {:error, :not_found}
  def get_pid(ets_table_id, key) do
    get(ets_table_id, key)
  end

  def get(ets_table_id, key) do
    case lookup(ets_table_id, key) do
      {:ok, pre_resolve_value} -> resolve_value(pre_resolve_value, key, ets_table_id)
      {:error, :not_found} -> {:error, :not_found}
    end
  end

  @doc """
  Add a value to the cache and monitor it if it is a pid.
  """
  @spec put(atom, PayDayLoan.key, term) :: :ok
  def put(id, key, value) do
    :ets.insert(id, {key, value})
    if is_pid(value) do
      GenServer.cast(id, {:monitor, value})
    end
    :ok
  end

  @doc """
  Look up a pid without checking if the pid is alive
  """
  @spec lookup(atom, PayDayLoan.key) :: {:ok, pid} | {:error, :not_found}
  def lookup(ets_table_id, key) do
    case :ets.lookup(ets_table_id, key) do
      [{_key, pid}] -> {:ok, pid}
      [] -> {:error, :not_found}
    end
  end

  @doc """
  Remove a pid from cache
  """
  @spec delete_pid(atom, pid) :: :ok
  def delete_pid(ets_table_id, pid) do
    true = :ets.match_delete(ets_table_id, {:'_', pid})
    :ok
  end

  @doc """
  Remove a key from cache
  """
  @spec delete_key(atom, PayDayLoan.key) :: :ok
  def delete_key(ets_table_id, key) do
    true = :ets.delete(ets_table_id, key)
    :ok
  end

  ######################################################################
  # Monitor GenServer callbacks
  @spec init([PayDayLoan.t]) :: {:ok, State.t}
  def init([pdl]) do
    # monitor all existing pids, clean up if they have died
    #   (could happen when this process restarts)
    monitors = :ets.foldl(
      fn
        ({_k, pid}, acc) when is_pid(pid) ->
          if Process.alive?(pid) do
            ensure_monitored(acc, pid)
          else
            delete_pid(pdl.cache_state_manager, pid)
            Map.delete(acc, pid)
          end
        (_, acc) -> acc
      end,
      %{},
      pdl.cache_state_manager
    )

    {:ok, %State{pdl: pdl, monitors: monitors}}
  end

  @spec handle_cast({:monitor, pid}, State.t) :: {:noreply, State.t}
  def handle_cast({:monitor, pid}, state) do
    monitors = ensure_monitored(state.monitors, pid)
    {:noreply, %{state | monitors: monitors}}
  end

  @spec handle_info({:DOWN, term, :process, pid, term}, State.t)
  :: {:noreply, State.t}
  def handle_info({:DOWN, _, :process, pid, _}, state) do
    delete_pid(state.pdl.cache_state_manager, pid)
    monitors = remove_monitor(state.monitors, pid)
    {:noreply, %{state | monitors: monitors}}
  end

  # make sure we only monitor pids once
  defp ensure_monitored(monitors, pid) do
    if Map.get(monitors, pid) do
      monitors
    else
      monitor_ref = Process.monitor(pid)
      Map.put(monitors, pid, monitor_ref)
    end
  end

  defp remove_monitor(monitors, pid) do
    Map.delete(monitors, pid)
  end

  defp resolve_value(cb, key, _ets_table_id) when is_function(cb, 1) do
    cb.(key)
  end
  defp resolve_value(pid, _key, ets_table_id) when is_pid(pid) do
    if Process.alive?(pid) do
      {:ok, pid}
    else
      :ok = delete_pid(ets_table_id, pid)
      {:error, :not_found}
    end
  end
  defp resolve_value(value, _key, _ets_table_id), do: {:ok, value}
end
