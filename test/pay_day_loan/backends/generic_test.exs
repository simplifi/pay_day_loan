defmodule PayDayLoan.Backends.GenericTest do
  use ExUnit.Case

  alias PayDayLoan, as: PDL

  import PayDayLoanTest.Support, only: [wait_for: 1]

  alias PayDayLoanTest.Support.LoadHistory

  defmodule CacheLogger do
    def start_link do
      Agent.start_link(fn -> [] end, name: __MODULE__)
    end

    def log(event, key) do
      Agent.update(__MODULE__, fn l -> [{event, key} | l] end)
    end

    def logs do
      Agent.get(__MODULE__, & &1)
    end
  end

  defmodule CacheBackend do
    def start_link() do
      Agent.start_link(fn -> %{} end, name: __MODULE__)
    end

    def get(key) do
      case Agent.get(__MODULE__, fn m -> Map.get(m, key) end) do
        nil -> {:error, :not_found}
        value -> {:ok, value}
      end
    end

    def put(key, value) do
      Agent.update(__MODULE__, fn m -> Map.put(m, key, "V#{value}") end)
    end

    def delete(key) do
      Agent.update(__MODULE__, fn m -> Map.delete(m, key) end)
    end
  end

  # loader behaviour implementation
  defmodule Implementation do
    use PayDayLoan.Support.TestImplementation

    def on_new(key, value) do
      CacheBackend.put(key, value)
      {:ok, &CacheBackend.get/1}
    end

    def on_remove(key, _value) do
      CacheBackend.delete(key)
    end

    def on_replace(_old_value, key, _value) do
      CacheBackend.put(key, "replaced")
      {:ok, &CacheBackend.get/1}
    end

    def on_update(_old_value, key, value) do
      CacheBackend.put(key, value)
      {:ok, &CacheBackend.get/1}
    end
  end

  # our cache for testing
  defmodule Cache do
    # we override batch_size here so we can test overrides -
    #   this is not necessary in general use
    use(
      PayDayLoan,
      batch_size: 10,
      load_wait_msec: 50,
      event_loggers: [&CacheLogger.log/2],
      callback_module: PayDayLoan.Backends.GenericTest.Implementation
    )
  end

  use PayDayLoan.Support.CommonTests, cache: Cache

  setup do
    CacheLogger.start_link()
    CacheBackend.start_link()
    :ok
  end

  test "basic integration test" do
    key = 1

    assert 0 == Cache.pdl().backend.size(Cache.pdl())

    assert {:error, :not_found} == PDL.peek(Cache.pdl(), key)
    assert :requested == PDL.query_load_state(Cache.pdl(), key)

    GenServer.cast(Cache.pdl().load_worker, :ping)
    Patiently.wait_for!(fn -> :loaded == Cache.peek_load_state(key) end)

    get_result = Cache.get(key)
    assert :loaded == PDL.query_load_state(Cache.pdl(), key)
    assert get_result == PDL.peek(Cache.pdl(), key)

    assert PDL.KeyCache.in_cache?(Cache.pdl().key_cache, key)
    assert [] == CacheLogger.logs()

    assert %{
             requested: 0,
             loaded: 1,
             loading: 0,
             failed: 0,
             reload: 0,
             reload_loading: 0
           } == Cache.load_state_stats()
  end

  test "loading happens in bulk" do
    n = 10

    tasks =
      1..n
      |> Enum.map(fn ix ->
        Task.async(fn ->
          {:ok, _pid} = Cache.get(ix)
        end)
      end)

    Enum.each(tasks, fn task -> Task.await(task) end)
    assert n == Cache.size()

    refute Enum.empty?(LoadHistory.bulk_loads())
    assert n == length(LoadHistory.news())
    assert Enum.empty?(LoadHistory.refreshes())

    1..n
    |> Enum.each(fn ix ->
      assert PDL.KeyCache.in_cache?(Cache.pdl().key_cache, ix)
    end)

    assert n == length(CacheLogger.logs())

    for ix <- 1..n do
      assert {:cache_miss, ix} in CacheLogger.logs()
    end
  end

  test "refreshing a cache element" do
    replaced_key = Implementation.key_that_shall_be_replaced()

    assert {:ok, "V1"} == Cache.get(1)
    assert {:ok, "V#{replaced_key}"} == Cache.get(replaced_key)

    news = LoadHistory.news()
    assert 2 == length(news)
    assert Enum.member?(news, {:new, [1, 1]})
    assert Enum.member?(news, {:new, [replaced_key, replaced_key]})

    assert {:ok, "V1"} == CacheBackend.get(1)
    assert {:ok, "V#{replaced_key}"} == CacheBackend.get(replaced_key)

    Cache.request_load([1, replaced_key])

    wait_for(fn ->
      !PDL.LoadState.any_requested?(Cache.pdl().load_state_manager)
    end)

    assert {:ok, "V1"} == Cache.get(1)
    assert {:ok, "V1"} == CacheBackend.get(1)

    assert {:ok, "Vreplaced"} == Cache.get(replaced_key)
    assert {:ok, "Vreplaced"} == CacheBackend.get(replaced_key)

    refreshes = LoadHistory.refreshes()
    assert 2 == length(refreshes)
    assert Enum.member?(refreshes, {:refresh, ["V1", 1, 1]})

    assert Enum.member?(
             refreshes,
             {:refresh, ["V#{replaced_key}", replaced_key, replaced_key]}
           )

    assert [cache_miss: replaced_key, cache_miss: 1] == CacheLogger.logs()
  end

  test "requesting a key that is in key cache but fails to load" do
    key = Implementation.key_that_shall_not_be_loaded()

    assert {:error, :failed} == Cache.get(key)
    assert [{:loaded, [key]}] == LoadHistory.loads()
    assert nil == PDL.LoadState.peek(Cache.pdl().load_state_manager, key)
    # we hold onto the knowledge that the key exists
    assert PDL.KeyCache.in_cache?(Cache.pdl().key_cache, key)

    assert [failed: key, cache_miss: key] == CacheLogger.logs()
  end

  test "requesting a key that does not exist" do
    key = Implementation.key_that_does_not_exist()

    assert {:error, :not_found} == Cache.get(key)
    assert [] == LoadHistory.loads()
    refute PDL.KeyCache.in_cache?(Cache.pdl().key_cache, key)

    assert [no_key: key] == CacheLogger.logs()
  end

  test "large batches don't require an extra ping" do
    batch_size = Cache.pdl().batch_size
    keys = Enum.to_list(1..(2 * batch_size))

    Cache.request_load(keys)

    wait_for(fn -> length(keys) == Cache.size() end)

    assert length(keys) == Cache.size()
  end

  test "load failures are ignored (should be handled in callback)" do
    key = Implementation.key_that_will_not_new()
    assert {:error, :failed} == Cache.get(key)
    # should get cleared from the load state cache
    assert nil == PDL.peek_load_state(Cache.pdl(), key)

    assert [failed: key, cache_miss: key] == CacheLogger.logs()
  end

  test "refresh failures are ignored (should be handled in callback)" do
    key = Implementation.key_that_will_not_refresh()

    # it should load
    {:ok, _value} = Cache.get(key)

    Cache.request_load(key)

    # the refresh fixture will delete the existing value
    wait_for(fn -> CacheBackend.get(key) == {:error, :not_found} end)

    # fail to refresh
    assert {:error, :failed} == Cache.get(key)
    # should get cleared from the load state cache
    assert nil == PDL.peek_load_state(Cache.pdl(), key)

    assert [failed: key, cache_miss: key] == CacheLogger.logs()
  end

  test "working with key/value lists" do
    n = 10

    tasks =
      1..n
      |> Enum.map(fn ix ->
        Task.async(fn ->
          {:ok, _value} = Cache.get(ix)
        end)
      end)

    Enum.each(tasks, fn task -> Task.await(task) end)
    assert n == Cache.size()

    expect_keys = Enum.to_list(1..n)
    expect_values = Enum.map(expect_keys, fn k -> "V#{k}" end)

    assert MapSet.new(expect_keys) == MapSet.new(Cache.keys())
    assert MapSet.new(expect_values) == MapSet.new(Cache.values())

    expect_map =
      Enum.reduce(expect_keys, %{}, fn k, acc ->
        {:ok, value} = CacheBackend.get(k)
        Map.put(acc, k, value)
      end)

    got_map =
      Cache.reduce(
        %{},
        fn {k, value}, acc -> Map.put(acc, k, value) end
      )

    assert expect_map == got_map
  end

  test "when a value is removed from the backend, its key is unloaded" do
    key = Implementation.key_that_is_removed_from_backend()
    {:ok, v1} = Cache.get(key)

    assert {:ok, v1} == CacheBackend.get(key)

    key2 = 2
    {:ok, v2} = Cache.get(key2)

    # delete on the backend
    CacheBackend.delete(key)

    # the deleted key no longer shows up in reduce results
    assert [v2] == Cache.values()

    assert {:error, :failed} == Cache.get(key)
    assert nil == PDL.LoadState.peek(Cache.pdl().load_state_manager, key)
    # we hold onto the knowledge that the key exists
    assert PDL.KeyCache.in_cache?(Cache.pdl().key_cache, key)

    expect_logs = [
      failed: key,
      cache_miss: key,
      disappeared: key,
      cache_miss: 2,
      cache_miss: key
    ]

    assert expect_logs == CacheLogger.logs()
  end

  test "when the monitor is killed, it restarts" do
    {:ok, "V1"} = Cache.get(1)

    previous_pid = Process.whereis(Cache.pdl().cache_monitor)

    :ok = GenServer.stop(Cache.pdl().cache_monitor)

    # make sure that it restarts via the supervisor
    wait_for(fn ->
      pid = Process.whereis(Cache.pdl().cache_monitor)
      is_pid(pid) && Process.alive?(pid)
    end)

    refute previous_pid == Process.whereis(Cache.pdl().cache_monitor)

    # cache state is unchanged
    assert {:ok, "V1"} == Cache.get(1)
  end

  test "manually adding an element to the cache" do
    CacheBackend.put(1, 42)
    Cache.cache(1, &CacheBackend.get/1)

    assert [1] == Cache.keys()
    assert ["V42"] == Cache.values()

    assert {:ok, "V42"} == Cache.get(1)

    # can't be manually overwritten
    assert {:error, "V42"} == Cache.cache(1, 0)

    assert [] == CacheLogger.logs()
  end

  test "manually removing an element from the cache" do
    {:ok, v} = Cache.get(1)

    assert {:ok, v} == Cache.get(1)

    :ok = PayDayLoan.uncache_key(Cache.pdl(), 1)

    assert [] == Cache.keys()
    assert [] == Cache.values()

    # value is still in the backend
    assert {:ok, "V1"} == CacheBackend.get(1)

    assert [cache_miss: 1] == CacheLogger.logs()
  end

  test "when new returns :ignore" do
    key = Implementation.key_that_returns_ignore_on_new()
    assert {:error, :failed} == Cache.get(key)
    # should get cleared from the load state cache
    assert nil == PDL.peek_load_state(Cache.pdl(), key)

    assert [failed: key, cache_miss: key] == CacheLogger.logs()
  end

  test "refresh :ignore failures are ignored (should be handled in callback)" do
    key = Implementation.key_that_returns_ignore_on_refresh()

    # it should load
    {:ok, _v} = Cache.get(key)

    Cache.request_load(key)

    # the refresh fixture will remove the existing value
    wait_for(fn -> CacheBackend.get(key) == {:error, :not_found} end)

    # fail to refresh
    assert {:error, :failed} == Cache.get(key)
    # should get cleared from the load state cache
    assert nil == PDL.peek_load_state(Cache.pdl(), key)

    assert [failed: key, cache_miss: key] == CacheLogger.logs()
  end

  test "when a key fails to load before the timeout" do
    key = Implementation.key_that_loads_too_slowly()

    assert {:error, :timed_out} == Cache.get(key)

    assert [timed_out: key, blocked: key, cache_miss: key] ==
             Enum.uniq(CacheLogger.logs())
  end

  test "working with the load state for lists of keys" do
    assert [:requested] ==
             PDL.LoadState.query(Cache.pdl().load_state_manager, [1])

    assert [:requested, nil] ==
             PDL.LoadState.peek(Cache.pdl().load_state_manager, [1, 2])

    assert [:loaded] ==
             PDL.LoadState.loaded(Cache.pdl().load_state_manager, [2])

    assert [:failed] ==
             PDL.LoadState.failed(Cache.pdl().load_state_manager, [1])
  end

  test "cache generator exports all of the desired shortcut functions" do
    base_functions = PayDayLoan.__info__(:functions)

    wanted_functions =
      Enum.reject(
        base_functions,
        fn {f, _} ->
          Enum.member?([:__struct__, :merge_defaults], f)
        end
      )

    for {f, arity} <- wanted_functions do
      assert :erlang.function_exported(Cache, f, arity - 1),
             "Function #{inspect(f)} not exported"
    end
  end
end
