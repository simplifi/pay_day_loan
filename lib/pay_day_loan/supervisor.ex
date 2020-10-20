defmodule PayDayLoan.Supervisor do
  @moduledoc """
  Supervisor for PDL processes.

  You can either start this manually or use
  `PayDayLoan.supervisor_specification/1` to return a supervisor spec
  that can be passed into another supervisor's start_link call (recommended).
  """

  use Supervisor

  alias PayDayLoan.ProcessMonitor
  alias PayDayLoan.LoadState
  alias PayDayLoan.LoadWorker
  alias PayDayLoan.KeyCache

  @doc "Start in a supervision tree"
  @spec start_link(PayDayLoan.t()) :: Supervisor.on_start()
  def start_link(pdl = %PayDayLoan{}) do
    Supervisor.start_link(__MODULE__, [pdl], name: pdl.supervisor_name)
  end

  # Supervisor callback
  @spec init([PayDayLoan.t()]) ::
          {:ok, {:supervisor.sup_flags(), [Supervisor.Spec.spec()]}}
  def init([pdl]) do
    setup(pdl)

    children =
      Enum.reject(
        [monitor_worker(pdl), load_worker(pdl)],
        &(&1 == nil)
      )

    supervise(children, strategy: :one_for_one)
  end

  defp monitor_worker(%PayDayLoan{cache_monitor: false}), do: nil

  defp monitor_worker(pdl) do
    worker(ProcessMonitor, [pdl, [name: pdl.cache_monitor]])
  end

  defp load_worker(pdl) do
    worker(LoadWorker, [pdl, [name: pdl.load_worker]])
  end

  defp setup(pdl = %PayDayLoan{}) do
    :ok = LoadState.create_table(pdl.load_state_manager)
    :ok = KeyCache.create_table(pdl.key_cache)
    :ok = pdl.backend.setup(pdl)
  end
end
