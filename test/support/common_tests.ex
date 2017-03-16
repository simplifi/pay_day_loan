defmodule PayDayLoan.Support.CommonTests do
  alias PayDayLoanTest.Support.LoadHistory

  defmacro __using__(opts \\ []) do
    cache = opts[:cache]
    quote location: :keep do
      import PayDayLoanTest.Support, only: [wait_for: 1]

      setup do
        LoadHistory.start
    
        wait_for(fn -> Process.whereis(PDLTestSup) == nil end)
        sup_spec = PayDayLoan.supervisor_specification(unquote(cache).pdl())
    
        {:ok, _sup_pid} = Supervisor.start_link(
          [sup_spec],
          strategy: :one_for_one,
          name: PDLTestSup
        )
    
        on_exit fn ->
          LoadHistory.stop
        end
    
        :ok
      end
    end
  end
end
