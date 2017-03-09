defmodule ProcessCacheTest do
  use ExUnit.Case

  alias PayDayLoan, as: PDL

  # repeatedly call pred_callback until it returns true
  #   - no dwell between iterations and no timeout
  def wait_for(pred_callback) do
    Stream.repeatedly(fn -> !pred_callback.() end)
    |> Stream.drop_while(&(&1))
    |> Enum.take(1)
  end

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
    @behaviour PayDayLoan.Loader

    @key_that_shall_be_replaced "key that shall be replaced" 
    @key_that_does_not_exist "key that does not exist"
    @key_that_will_not_new "key that will not new"
    @key_that_will_not_refresh "key that will not refresh"
    @key_that_returns_ignore_on_new "key that returns ignore on new"
    @key_that_returns_ignore_on_refresh "key that returns ignore on refresh"

    # we'll refuse to load this key
    def key_that_shall_not_be_loaded do
      "key that shall not be loaded"
    end

    # this one will get a new pid
    def key_that_shall_be_replaced do
      @key_that_shall_be_replaced
    end

    # this one will fail the key cache check
    def key_that_does_not_exist do
      @key_that_does_not_exist
    end

    # this key will return an error on new
    def key_that_will_not_new do
      @key_that_will_not_new
    end

    # this key will return an error on refresh
    def key_that_will_not_refresh do
      @key_that_will_not_refresh
    end

    # this key will return :ignore on new
    def key_that_returns_ignore_on_new do
      @key_that_returns_ignore_on_new
    end

    def key_that_returns_ignore_on_refresh do
      @key_that_returns_ignore_on_refresh
    end

    def bulk_load(keys) do
      LoadHistory.loaded(keys)

      keys = keys
      |> Enum.filter(fn(k) ->
        k != key_that_shall_not_be_loaded()
      end)

      Enum.map(keys, fn(key) -> {key, key} end)
    end

    def new(key = @key_that_will_not_new, value) do
      LoadHistory.new(key, value)
      {:error, :load_failed}
    end
    def new(key = @key_that_returns_ignore_on_new, value) do
      LoadHistory.new(key, value)
      :ignore
    end
    def new(key, value) do
      LoadHistory.new(key, value)
      Agent.start(fn() -> [{key, value}] end)
    end

    def refresh(pid, key = @key_that_will_not_refresh, value) do
      LoadHistory.refresh(pid, key, value)
      # stop the previous pid
      Agent.stop(pid)
      # return error
      {:error, :refresh_failed}
    end
    def refresh(pid, key = @key_that_returns_ignore_on_refresh, value) do
      LoadHistory.refresh(pid, key, value)
      # stop the previous pid
      Agent.stop(pid)
      # return ignore
      :ignore
    end
    def refresh(pid, key = @key_that_shall_be_replaced, value) do
      LoadHistory.refresh(pid, key, value)
      # stop the previous pid
      Agent.stop(pid)
      # create a new one
      Agent.start(fn() -> [{key, value}] end)
    end
    def refresh(pid, key, value) do
      LoadHistory.refresh(pid, key, value)
      Agent.update(pid, fn(values) -> [{key, value} | values] end)
      {:ok, pid}
    end

    def key_exists?(@key_that_does_not_exist), do: false
    def key_exists?(_key), do: true
  end

  setup do
    LoadHistory.start

    wait_for(fn -> Process.whereis(PDLTestSup) == nil end)

    pdl = PDLTestProcessCache.pdl
    sup_spec = PayDayLoan.supervisor_specification(pdl)

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

  test "basic integration test" do
    pdl = PDLTestProcessCache.pdl

    assert 0 == PDL.CacheStateManager.size(pdl.cache_state_manager)

    assert {:error, :not_found} == PDL.peek_pid(pdl, 1)

    assert :requested == PDL.query_load_state(pdl, 1)

    GenServer.cast(pdl.load_worker, :ping)

    {:ok, pid} = PDLTestProcessCache.get_pid(1)

    assert :loaded == PDL.query_load_state(pdl, 1)

    assert {:ok, pid} == PDL.peek_pid(pdl, 1)

    assert [{1, 1}] == Agent.get(pid, fn(v) -> v end)

    assert PDL.KeyCache.in_cache?(pdl.key_cache, 1)
  end

  test "loading happens in bulk" do
    pdl = PDLTestProcessCache.pdl

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
      assert PDL.KeyCache.in_cache?(pdl.key_cache, ix)
    end)
  end

  test "refreshing a cache element" do
    pdl = PDLTestProcessCache.pdl
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
        PDL.LoadState.any_requested?(pdl.load_state_manager)
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
    # reduce the load wait time to make the test go by faster
    pdl = %{ PDLTestProcessCache.pdl | load_wait_msec: 10 }

    key = PDLTestProcessImplementation.key_that_shall_not_be_loaded

    assert {:error, :failed} == PDLTestProcessCache.get_pid(key)
    assert [{:loaded, [key]}] == LoadHistory.loads
    assert nil == PDL.LoadState.peek(pdl.load_state_manager, key)
    # we hold onto the knowledge that the key exists
    assert PDL.KeyCache.in_cache?(pdl.key_cache, key)
  end

  test "requesting a key that does not exist" do
    pdl = PDLTestProcessCache.pdl

    key = PDLTestProcessImplementation.key_that_does_not_exist

    assert {:error, :not_found} == PDLTestProcessCache.get_pid(key)
    assert [] == LoadHistory.loads
    refute PDL.KeyCache.in_cache?(pdl.key_cache, key)
  end

  test "overriding defaults" do
    assert 10 == PDLTestProcessCache.pdl.batch_size
  end

  test "large batches don't require an extra ping" do
    batch_size = PDLTestProcessCache.pdl.batch_size
    keys = Enum.to_list(1..(2 * batch_size))

    PDLTestProcessCache.request_load(keys)

    wait_for(fn -> length(keys) == PDLTestProcessCache.size end)

    assert length(keys) == PDLTestProcessCache.size
  end

  test "load failures are ignored (should be handled in callback)" do
    key = PDLTestProcessImplementation.key_that_will_not_new
    assert {:error, :failed} == PDLTestProcessCache.get_pid(key)
    # should get cleared from the load state cache
    assert nil == PDL.peek_load_state(PDLTestProcessCache.pdl, key)
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
    assert nil == PDL.peek_load_state(PDLTestProcessCache.pdl, key)
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

    assert {:error, :not_found} == PDL.peek_pid(PDLTestProcessCache.pdl, 1)

    {:ok, pid2} = PDLTestProcessCache.get_pid(1)

    assert Process.alive?(pid2)
    refute pid1 == pid2
  end

  test "when the monitor is killed, it restarts and starts monitoring again" do
    pdl = PDLTestProcessCache.pdl

    {:ok, pid1} = PDLTestProcessCache.get_pid(1)

    previous_pid = Process.whereis(pdl.cache_state_manager)

    :ok = GenServer.stop(pdl.cache_state_manager)

    # make sure that it restarts via the supervisor
    wait_for(fn ->
      pid = Process.whereis(pdl.cache_state_manager)
      is_pid(pid) && Process.alive?(pid)
    end)

    refute previous_pid == Process.whereis(pdl.cache_state_manager)

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

    :ok = PayDayLoan.uncache_key(PDLTestProcessCache.pdl, 1)

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
    assert nil == PDL.peek_load_state(PDLTestProcessCache.pdl, key)
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
    assert nil == PDL.peek_load_state(PDLTestProcessCache.pdl, key)
  end

  test "callback_module is a required option for `use PayDayLoan`" do
    assert_raise ArgumentError, fn ->
      PayDayLoan.CacheGenerator.compile([])
    end
  end
end
