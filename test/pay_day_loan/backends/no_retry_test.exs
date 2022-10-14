defmodule PayDayLoan.Backends.NoRetryTest do
  use ExUnit.Case

  alias PayDayLoan, as: PDL

  import PayDayLoanTest.Support, only: [wait_for: 1]

  alias PayDayLoanTest.Support.LoadHistory
  alias PayDayLoan.LoadState

  # our cache for testing
  defmodule Cache do
    # we override batch_size here so we can test overrides -
    #   this is not necessary in general use
    use(
      PayDayLoan,
      batch_size: 10,
      load_num_tries: 1,
      load_wait_msec: 50,
      callback_module: PayDayLoan.Backends.NoRetryTest.Implementation
    )
  end

  # loader behaviour implementation
  defmodule Implementation do
    use PayDayLoan.Support.TestImplementation

    def on_new(_key, value) do
      {:ok, value}
    end

    def on_remove(key, _value) do
    end

    def on_replace(_old_value, _key, _value) do
      {:ok, "replaced"}
    end

    def on_update(_old_value, _key, value) do
      {:ok, value}
    end
  end

  use PayDayLoan.Support.CommonTests, cache: Cache

  test "requesting a key that causes a timeout crash in the load process" do
    reloading_key = Implementation.key_that_reloads_slowly()

    Patiently.wait_for!(fn ->
      {result, _} = Cache.get(reloading_key)
      result == :ok
    end)

    LoadState.reload_loading(Cache.pdl().load_state_manager, reloading_key)

    key = Implementation.key_that_times_out_during_bulk_load()
    assert {:error, :timed_out} == Cache.get(key)

    # The keys should no longer exist in the load state - unload is supposed to remove them.
    assert nil == PDL.peek_load_state(Cache.pdl(), key)
    assert nil == PDL.peek_load_state(Cache.pdl(), reloading_key)

    # The final check is that even after a previous failure, the keys are marked requested
    # when we try to get them:
    assert :requested == PDL.query_load_state(Cache.pdl(), key)
    assert :requested == PDL.query_load_state(Cache.pdl(), reloading_key)
  end
end
