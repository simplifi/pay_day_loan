defmodule PayDayLoan.Backends.ProcessTest do
  use ExUnit.Case

  alias PayDayLoan, as: PDL

  import PayDayLoanTest.Support, only: [wait_for: 1]

  alias PayDayLoanTest.Support.LoadHistory

  # our cache for testing
  defmodule Cache do
    # we override batch_size here so we can test overrides -
    #   this is not necessary in general use
    use(
      PayDayLoan,
      batch_size: 10,
      load_wait_msec: 50,
      callback_module: PayDayLoan.Backends.ProcessTest.Implementation
    )
  end

  # loader behaviour implementation
  defmodule Implementation do
    use PayDayLoan.Support.TestImplementation

    def on_new(key, value) do
      Agent.start(fn() -> [{key, value}] end)
    end

    def on_remove(_key, value) do
      Agent.stop(value)
    end

    def on_replace(old_value, key, value) do
      on_remove(key, old_value)
      on_new(key, value)
    end

    def on_update(old_value, key, value) do
      Agent.update(old_value, fn(values) -> [{key, value} | values] end)
      {:ok, old_value}
    end
  end

  use PayDayLoan.Support.CommonTests, cache: Cache

  test "basic integration test" do
    key = 1

    assert 0 == Cache.pdl().backend.size(Cache.pdl())

    assert {:error, :not_found} == PDL.peek(Cache.pdl(), key)
    assert :requested == PDL.query_load_state(Cache.pdl(), key)

    GenServer.cast(Cache.pdl().load_worker, :ping)

    get_result = Cache.get(key)
    assert :loaded == PDL.query_load_state(Cache.pdl(), key)
    assert get_result == PDL.peek(Cache.pdl(), key)

    {:ok, pid} = Cache.get(key)
    assert {:ok, pid} == PDL.peek(Cache.pdl(), key)

    assert [{key, key}] == Agent.get(pid, fn(v) -> v end)

    assert PDL.KeyCache.in_cache?(Cache.pdl().key_cache, key)
  end

  test "loading happens in bulk" do
    n = 10

    tasks = (1..n)
    |> Enum.map(fn(ix) ->
      Task.async(fn ->
        {:ok, _pid} = Cache.get(ix)
      end)
    end)

    Enum.each(tasks, fn(task) -> Task.await(task) end)
    assert n == Cache.size

    assert length(LoadHistory.bulk_loads) > 0
    assert n == length(LoadHistory.news)
    assert 0 == length(LoadHistory.refreshes)

    (1..n)
    |> Enum.each(fn(ix) ->
      assert PDL.KeyCache.in_cache?(Cache.pdl().key_cache, ix)
    end)
  end

  test "refreshing a cache element" do
    replaced_key = Implementation.key_that_shall_be_replaced

    {:ok, pid1} = Cache.get(1)
    {:ok, pid2} = Cache.get(replaced_key)

    news = LoadHistory.news
    assert 2 == length(news)
    assert Enum.member?(news, {:new, [1, 1]})
    assert Enum.member?(news, {:new, [replaced_key, replaced_key]})

    assert [{1, 1}] == Agent.get(pid1, &(&1))
    assert [{replaced_key, replaced_key}] == Agent.get(pid2, &(&1))

    Cache.request_load([1, replaced_key])

    wait_for(
      fn ->
        !PDL.LoadState.any_requested?(Cache.pdl().load_state_manager)
      end
    )

    assert {:ok, pid1} == Cache.get(1)
    assert [{1, 1}, {1, 1}] == Agent.get(pid1, &(&1))

    {:ok, pid2_new} = Cache.get(replaced_key)
    assert pid2_new != pid2
    assert [{replaced_key, replaced_key}] == Agent.get(pid2_new, &(&1))

    refreshes = LoadHistory.refreshes
    assert 2 == length(refreshes)
    assert Enum.member?(refreshes, {:refresh, [pid1, 1, 1]})
    assert Enum.member?(
      refreshes,
      {:refresh, [pid2, replaced_key, replaced_key]}
    )
  end

  test "requesting a key that is in key cache but fails to load" do
    key = Implementation.key_that_shall_not_be_loaded

    assert {:error, :failed} == Cache.get(key)
    assert [{:loaded, [key]}] == LoadHistory.loads
    assert nil == PDL.LoadState.peek(Cache.pdl().load_state_manager, key)
    # we hold onto the knowledge that the key exists
    assert PDL.KeyCache.in_cache?(Cache.pdl().key_cache, key)
  end

  test "requesting a key that does not exist" do
    key = Implementation.key_that_does_not_exist

    assert {:error, :not_found} == Cache.get(key)
    assert [] == LoadHistory.loads
    refute PDL.KeyCache.in_cache?(Cache.pdl().key_cache, key)
  end

  test "overriding defaults" do
    assert 10 == Cache.pdl().batch_size
  end

  test "large batches don't require an extra ping" do
    batch_size = Cache.pdl().batch_size
    keys = Enum.to_list(1..(2 * batch_size))

    Cache.request_load(keys)

    wait_for(fn -> length(keys) == Cache.size end)

    assert length(keys) == Cache.size
  end

  test "load failures are ignored (should be handled in callback)" do
    key = Implementation.key_that_will_not_new
    assert {:error, :failed} == Cache.get(key)
    # should get cleared from the load state cache
    assert nil == PDL.peek_load_state(Cache.pdl(), key)
  end

  test "refresh failures are ignored (should be handled in callback)" do
    key = Implementation.key_that_will_not_refresh

    # it should load
    {:ok, pid} = Cache.get(key)

    Cache.request_load(key)

    # the refresh fixture will kill the existing pid
    wait_for(fn -> !Process.alive?(pid) end)

    # fail to refresh
    assert {:error, :failed} == Cache.get(key)
    # should get cleared from the load state cache
    assert nil == PDL.peek_load_state(Cache.pdl(), key)
  end

  test "working with key/pid lists" do
    n = 10

    tasks = (1..n)
    |> Enum.map(fn(ix) ->
      Task.async(fn ->
        {:ok, _pid} = Cache.get(ix)
      end)
    end)

    Enum.each(tasks, fn(task) -> Task.await(task) end)
    assert n == Cache.size

    expect_keys = Enum.to_list(1..n)
    expect_pids = Enum.map(
      expect_keys,
      fn(key) -> {:ok, pid} = Cache.get(key); pid end
    )

    assert MapSet.new(expect_keys) == MapSet.new(Cache.keys)
    assert MapSet.new(expect_pids) == MapSet.new(Cache.pids)

    expect_map = Enum.reduce(expect_keys, %{},
      fn(k, acc) ->
        {:ok, pid} = Cache.get(k)
        Map.put(acc, k, pid)
      end)
    
    got_map = Cache.reduce(%{},
      fn({k, pid}, acc) -> Map.put(acc, k, pid) end)

    assert expect_map == got_map
  end

  test "when a pid is killed, it is unloaded and can be reloaded" do
    {:ok, pid1} = Cache.get(1)

    assert Process.alive?(pid1)

    Agent.stop(pid1)

    assert {:error, :not_found} == PDL.peek(Cache.pdl(), 1)

    {:ok, pid2} = Cache.get(1)

    assert Process.alive?(pid2)
    refute pid1 == pid2
  end

  test "when the monitor is killed, it restarts and starts monitoring again" do
    {:ok, pid1} = Cache.get(1)

    previous_pid = Process.whereis(Cache.pdl().cache_monitor)

    :ok = GenServer.stop(Cache.pdl().cache_monitor)

    # make sure that it restarts via the supervisor
    wait_for(fn ->
      pid = Process.whereis(Cache.pdl().cache_monitor)
      is_pid(pid) && Process.alive?(pid)
    end)

    refute previous_pid == Process.whereis(Cache.pdl().cache_monitor)

    # the new monitor should be monitoring the pid now
    Agent.stop(pid1)

    # so when we stop that pid, it should be removed from cache
    wait_for(fn -> [] == Cache.keys end)
  end

  test "manually adding an element to the cache" do
    {:ok, pid} = Agent.start(fn -> 1 end)

    Cache.cache(1, pid)

    assert [1] == Cache.keys
    assert [pid] == Cache.pids

    # make sure it's monitored and gets removed on death
    Agent.stop(pid)
    wait_for(fn -> [] == Cache.keys end)
  end

  test "manually removing an element from the cache" do
    {:ok, pid} = Cache.get(1)

    assert {:ok, pid} == Cache.get(1)

    :ok = PayDayLoan.uncache_key(Cache.pdl(), 1)

    assert [] == Cache.keys
    assert [] == Cache.pids

    assert Process.alive?(pid)

    Agent.stop(pid)

    {:ok, pid2} = Cache.get(1)
    refute pid == pid2
  end

  test "when new returns :ignore" do
    key = Implementation.key_that_returns_ignore_on_new
    assert {:error, :failed} == Cache.get(key)
    # should get cleared from the load state cache
    assert nil == PDL.peek_load_state(Cache.pdl(), key)
  end

  test "refresh :ignore failures are ignored (should be handled in callback)" do
    key = Implementation.key_that_returns_ignore_on_refresh

    # it should load
    {:ok, pid} = Cache.get(key)

    Cache.request_load(key)

    # the refresh fixture will kill the existing pid
    wait_for(fn -> !Process.alive?(pid) end)

    # fail to refresh
    assert {:error, :failed} == Cache.get(key)
    # should get cleared from the load state cache
    assert nil == PDL.peek_load_state(Cache.pdl(), key)
  end

  test "reloading does not block" do
    key = Implementation.key_that_reloads_slowly

    {:ok, v} = Cache.get(key)

    Cache.request_load(key)
    # if we call this immediately, we should get the old value
    assert {:ok, v} == Cache.get(key)

    Patiently.wait_for!(fn ->
      {:ok, v_new} = Cache.get(key)
      v_new != v
    end)
    assert :loaded == Cache.peek_load_state(key)
    assert 1 == Cache.size
  end

  test "callback_module is a required option for `use PayDayLoan`" do
    assert_raise ArgumentError, fn ->
      PayDayLoan.CacheGenerator.compile([])
    end
  end

  test "failure callback for processes not found" do
    assert 1 == Cache.with_value(1, fn(_) -> 2 end, fn() -> 1 end)
  end
end
