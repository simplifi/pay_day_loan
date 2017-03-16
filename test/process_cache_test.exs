defmodule ProcessCacheTest do
  use ExUnit.Case

  alias PayDayLoan, as: PDL

  import PayDayLoanTest.Support, only: [wait_for: 1]

  alias PayDayLoanTest.Support.LoadHistory

  # our cache for testing
  defmodule PDLTestProcessCache do
    # we override batch_size here so we can test overrides -
    #   this is not necessary in general use
    use(
      PayDayLoan,
      batch_size: 10,
      load_wait_msec: 50,
      callback_module: ProcessCacheTest.PDLTestProcessImplementation
    )
  end

  # loader behaviour implementation
  defmodule PDLTestProcessImplementation do
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

  def pdl do
    PDLTestProcessCache.pdl()
  end

  use PayDayLoan.Support.CommonTests

  test "basic integration test" do
    assert 0 == PDL.EtsBackend.size(pdl())

    assert {:error, :not_found} == PDL.peek_pid(pdl(), 1)

    assert :requested == PDL.query_load_state(pdl(), 1)

    GenServer.cast(pdl().load_worker, :ping)

    {:ok, pid} = PDLTestProcessCache.get_pid(1)

    assert :loaded == PDL.query_load_state(pdl(), 1)

    assert {:ok, pid} == PDL.peek_pid(pdl(), 1)

    assert [{1, 1}] == Agent.get(pid, fn(v) -> v end)

    assert PDL.KeyCache.in_cache?(pdl().key_cache, 1)
  end

  test "loading happens in bulk" do
    n = 10

    tasks = (1..n)
    |> Enum.map(fn(ix) ->
      Task.async(fn ->
        {:ok, _pid} = PDLTestProcessCache.get_pid(ix)
      end)
    end)

    Enum.each(tasks, fn(task) -> Task.await(task) end)
    assert n == PDLTestProcessCache.size

    assert length(LoadHistory.bulk_loads) > 0
    assert n == length(LoadHistory.news)
    assert 0 == length(LoadHistory.refreshes)

    (1..n)
    |> Enum.each(fn(ix) ->
      assert PDL.KeyCache.in_cache?(pdl().key_cache, ix)
    end)
  end

  test "refreshing a cache element" do
    replaced_key = PDLTestProcessImplementation.key_that_shall_be_replaced

    {:ok, pid1} = PDLTestProcessCache.get_pid(1)
    {:ok, pid2} = PDLTestProcessCache.get_pid(replaced_key)

    news = LoadHistory.news
    assert 2 == length(news)
    assert Enum.member?(news, {:new, [1, 1]})
    assert Enum.member?(news, {:new, [replaced_key, replaced_key]})

    assert [{1, 1}] == Agent.get(pid1, &(&1))
    assert [{replaced_key, replaced_key}] == Agent.get(pid2, &(&1))

    PDLTestProcessCache.request_load([1, replaced_key])

    wait_for(
      fn ->
        PDL.LoadState.any_requested?(pdl().load_state_manager)
      end
    )

    assert {:ok, pid1} == PDLTestProcessCache.get_pid(1)
    assert [{1, 1}, {1, 1}] == Agent.get(pid1, &(&1))

    {:ok, pid2_new} = PDLTestProcessCache.get_pid(replaced_key)
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
    key = PDLTestProcessImplementation.key_that_shall_not_be_loaded

    assert {:error, :failed} == PDLTestProcessCache.get_pid(key)
    assert [{:loaded, [key]}] == LoadHistory.loads
    assert nil == PDL.LoadState.peek(pdl().load_state_manager, key)
    # we hold onto the knowledge that the key exists
    assert PDL.KeyCache.in_cache?(pdl().key_cache, key)
  end

  test "requesting a key that does not exist" do
    key = PDLTestProcessImplementation.key_that_does_not_exist

    assert {:error, :not_found} == PDLTestProcessCache.get_pid(key)
    assert [] == LoadHistory.loads
    refute PDL.KeyCache.in_cache?(pdl().key_cache, key)
  end

  test "overriding defaults" do
    assert 10 == pdl().batch_size
  end

  test "large batches don't require an extra ping" do
    batch_size = pdl().batch_size
    keys = Enum.to_list(1..(2 * batch_size))

    PDLTestProcessCache.request_load(keys)

    wait_for(fn -> length(keys) == PDLTestProcessCache.size end)

    assert length(keys) == PDLTestProcessCache.size
  end

  test "load failures are ignored (should be handled in callback)" do
    key = PDLTestProcessImplementation.key_that_will_not_new
    assert {:error, :failed} == PDLTestProcessCache.get_pid(key)
    # should get cleared from the load state cache
    assert nil == PDL.peek_load_state(pdl(), key)
  end

  test "refresh failures are ignored (should be handled in callback)" do
    key = PDLTestProcessImplementation.key_that_will_not_refresh

    # it should load
    {:ok, pid} = PDLTestProcessCache.get_pid(key)

    PDLTestProcessCache.request_load(key)

    # the refresh fixture will kill the existing pid
    wait_for(fn -> !Process.alive?(pid) end)

    # fail to refresh
    assert {:error, :failed} == PDLTestProcessCache.get_pid(key)
    # should get cleared from the load state cache
    assert nil == PDL.peek_load_state(pdl(), key)
  end

  test "working with key/pid lists" do
    n = 10

    tasks = (1..n)
    |> Enum.map(fn(ix) ->
      Task.async(fn ->
        {:ok, _pid} = PDLTestProcessCache.get_pid(ix)
      end)
    end)

    Enum.each(tasks, fn(task) -> Task.await(task) end)
    assert n == PDLTestProcessCache.size

    expect_keys = Enum.to_list(1..n)
    expect_pids = Enum.map(
      expect_keys,
      fn(key) -> {:ok, pid} = PDLTestProcessCache.get_pid(key); pid end
    )

    assert MapSet.new(expect_keys) == MapSet.new(PDLTestProcessCache.keys)
    assert MapSet.new(expect_pids) == MapSet.new(PDLTestProcessCache.pids)

    expect_map = Enum.reduce(expect_keys, %{},
      fn(k, acc) ->
        {:ok, pid} = PDLTestProcessCache.get_pid(k)
        Map.put(acc, k, pid)
      end)
    
    got_map = PDLTestProcessCache.reduce(%{},
      fn({k, pid}, acc) -> Map.put(acc, k, pid) end)

    assert expect_map == got_map
  end

  test "when a pid is killed, it is unloaded and can be reloaded" do
    {:ok, pid1} = PDLTestProcessCache.get_pid(1)

    assert Process.alive?(pid1)

    Agent.stop(pid1)

    assert {:error, :not_found} == PDL.peek_pid(pdl(), 1)

    {:ok, pid2} = PDLTestProcessCache.get_pid(1)

    assert Process.alive?(pid2)
    refute pid1 == pid2
  end

  test "when the monitor is killed, it restarts and starts monitoring again" do
    {:ok, pid1} = PDLTestProcessCache.get_pid(1)

    previous_pid = Process.whereis(pdl().cache_monitor)

    :ok = GenServer.stop(pdl().cache_monitor)

    # make sure that it restarts via the supervisor
    wait_for(fn ->
      pid = Process.whereis(pdl().cache_monitor)
      is_pid(pid) && Process.alive?(pid)
    end)

    refute previous_pid == Process.whereis(pdl().cache_monitor)

    # the new monitor should be monitoring the pid now
    Agent.stop(pid1)

    # so when we stop that pid, it should be removed from cache
    wait_for(fn -> [] == PDLTestProcessCache.keys end)
  end

  test "manually adding an element to the cache" do
    {:ok, pid} = Agent.start(fn -> 1 end)

    PDLTestProcessCache.cache(1, pid)

    assert [1] == PDLTestProcessCache.keys
    assert [pid] == PDLTestProcessCache.pids

    # make sure it's monitored and gets removed on death
    Agent.stop(pid)
    wait_for(fn -> [] == PDLTestProcessCache.keys end)
  end

  test "manually removing an element from the cache" do
    {:ok, pid} = PDLTestProcessCache.get_pid(1)

    assert {:ok, pid} == PDLTestProcessCache.get_pid(1)

    :ok = PayDayLoan.uncache_key(pdl(), 1)

    assert [] == PDLTestProcessCache.keys
    assert [] == PDLTestProcessCache.pids

    assert Process.alive?(pid)

    Agent.stop(pid)

    {:ok, pid2} = PDLTestProcessCache.get_pid(1)
    refute pid == pid2
  end

  test "when new returns :ignore" do
    key = PDLTestProcessImplementation.key_that_returns_ignore_on_new
    assert {:error, :failed} == PDLTestProcessCache.get_pid(key)
    # should get cleared from the load state cache
    assert nil == PDL.peek_load_state(pdl(), key)
  end

  test "refresh :ignore failures are ignored (should be handled in callback)" do
    key = PDLTestProcessImplementation.key_that_returns_ignore_on_refresh

    # it should load
    {:ok, pid} = PDLTestProcessCache.get_pid(key)

    PDLTestProcessCache.request_load(key)

    # the refresh fixture will kill the existing pid
    wait_for(fn -> !Process.alive?(pid) end)

    # fail to refresh
    assert {:error, :failed} == PDLTestProcessCache.get_pid(key)
    # should get cleared from the load state cache
    assert nil == PDL.peek_load_state(pdl(), key)
  end

  test "callback_module is a required option for `use PayDayLoan`" do
    assert_raise ArgumentError, fn ->
      PayDayLoan.CacheGenerator.compile([])
    end
  end
end
