defmodule PayDayLoan.CacheMonitor do
  @moduledoc """
  Monitor for process registry caches.

  This is built to work with the supplied `PayDayLoan.EtsBackend` backend, for
  which it monitors pids and removes them from cache if the pid dies.

  This can be disabled by setting `cache_monitor: false` in the PDL setup.
  """

  use GenServer

  defmodule State do
    @moduledoc false

    defstruct(pdl: nil, monitors: %{})
    @type t :: %__MODULE__{}
  end
  alias PayDayLoan.CacheMonitor.State

  # used by the supervisor
  @doc false
  @spec start_link(PayDayLoan.t, GenServer.options) :: GenServer.on_start
  def start_link(pdl = %PayDayLoan{}, gen_server_opts \\ []) do
    GenServer.start_link(__MODULE__, [pdl], gen_server_opts)
  end

  ######################################################################
  # GenServer callbacks
  @spec init([PayDayLoan.t]) :: {:ok, State.t}
  def init([pdl]) do
    # monitor all existing pids, clean up if they have died
    #   (could happen when this process restarts)
    monitors = Enum.reduce(pdl.backend.values(pdl), %{},
      fn
        ({_k, pid}, acc) when is_pid(pid) ->
          if Process.alive?(pid) do
            ensure_monitored(acc, pid)
          else
            pdl.backend.delete_value(pdl, pid)
            Map.delete(acc, pid)
          end
        (_, acc) -> acc
      end
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
  def handle_info({:DOWN, _, :process, pid, _}, state = %State{pdl: pdl}) do
    pdl.backend.delete_value(pdl, pid)
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
end
