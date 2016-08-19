defmodule PayDayLoan.Supervisor do
  @moduledoc """
  Supervisor for PDL processes.

  You can either start this manually or use
  `PayDayLoan.supervisor_specification/1` to return a supervisor spec
  that can be passed into another supervisor's start_link call (recommended).
  """

  use Supervisor

  alias PayDayLoan.CacheStateManager
  alias PayDayLoan.LoadState
  alias PayDayLoan.LoadWorker
  alias PayDayLoan.KeyCache

  @doc "Start in a supervision tree"
  @spec start_link(PayDayLoan.t) :: Supervisor.on_start
  def start_link(pdl = %PayDayLoan{}) do
    Supervisor.start_link(__MODULE__, [pdl], name: pdl.supervisor_name)
  end

  # Supervisor callback
  @doc false
  def init([pdl]) do
    create_tables(pdl)

    children = [
      worker(
        CacheStateManager,
        [
          pdl,
          [name: pdl.cache_state_manager]
        ]
      ),
      worker(
        LoadWorker,
        [
          pdl,
          [name: pdl.load_worker]
        ]
      )
    ]

    supervise(children, strategy: :one_for_one)
  end

  defp create_tables(pdl = %PayDayLoan{}) do
    LoadState.create_table(pdl.load_state_manager)
    KeyCache.create_table(pdl.key_cache)
    CacheStateManager.create_table(pdl.cache_state_manager)
  end
end
